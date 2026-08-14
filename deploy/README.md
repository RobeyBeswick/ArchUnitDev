# Deploying the loop to EC2

The only thing that genuinely needs care is credentials: the loop runs for hours, and anything
short-lived dies partway through the night. An instance profile refreshes itself, so it is the only
option that survives a full run unattended. `run.sh` refuses an unbounded run on static credentials
rather than discovering the problem at 03:00.

## 1. IAM role for the instance

Create a role with `bedrock-invoke-policy.json` attached, trusted by `ec2.amazonaws.com`, and attach
it to the instance as an instance profile.

```bash
ACCOUNT=<aws-account-id>

aws iam create-role --role-name ArchUnitDevLoop \
  --assume-role-policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
  }'

aws iam put-role-policy --role-name ArchUnitDevLoop \
  --policy-name BedrockInvoke \
  --policy-document file://bedrock-invoke-policy.json

aws iam create-instance-profile --instance-profile-name ArchUnitDevLoop
aws iam add-role-to-instance-profile \
  --instance-profile-name ArchUnitDevLoop --role-name ArchUnitDevLoop

aws ec2 associate-iam-instance-profile \
  --instance-id "$INSTANCE_ID" \
  --iam-instance-profile Name=ArchUnitDevLoop
```

## 2. Let the container reach IMDS

This is the step that silently breaks everything. EC2 defaults to
`http-put-response-hop-limit = 1`, and Docker's bridge network adds a hop — so the container cannot
reach IMDS at all, and credentials simply never resolve.

```bash
aws ec2 modify-instance-metadata-options \
  --instance-id "$INSTANCE_ID" \
  --http-tokens required \
  --http-put-response-hop-limit 2
```

Running the container with `--network host` avoids it instead.

## 3. Put the target repo and the log directory on the instance

Neither is in the image — both are bind-mounted, so they have to exist on the host first.

```bash
sudo dnf install -y docker git            # Amazon Linux 2023
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user          # log out and back in for this to take effect

git clone https://github.com/LukasNiessen/ArchUnitGo.git /home/ec2-user/ArchUnitGo
mkdir -p /home/ec2-user/logs
```

Two details that bite:

**Ownership.** The image runs as `dev`, UID 1000, and a bind mount carries the host's ownership
straight through — so both directories must be owned by UID 1000 or the loop cannot write. On Amazon
Linux `ec2-user` *is* 1000, so a clone made as `ec2-user` lines up. If you build with a different
`--build-arg UID`, match it.

**The checked-out branch is the branch the loop works on.** `run.sh` commits to whatever is checked
out and pushes `HEAD`; it never switches branches. A fresh clone is on `main`, which is what you want.

## 4. Check before committing to a night

```bash
docker run --rm -e GH_TOKEN -e PREFLIGHT_ONLY=1 \
  -v /home/ec2-user/ArchUnitGo:/work/repo -v /home/ec2-user/logs:/work/logs \
  archunitdev
```

Costs nothing. You want `auth: Bedrock in us-east-1 as arn:aws:sts::…:assumed-role/ArchUnitDevLoop/…`
and **no** static-credentials warning. Seeing `assumed-role/ArchUnitDevLoop` is the proof that the
instance profile — not a leftover environment variable — is what answered.

## 5. Run it

```bash
nohup docker run --rm \
  -e GH_TOKEN \
  -v /home/ec2-user/ArchUnitGo:/work/repo \
  -v /home/ec2-user/logs:/work/logs \
  archunitdev > /home/ec2-user/logs/loop.out 2>&1 &

tail -f /home/ec2-user/logs/run.log
```

`loop.out` goes *inside* the log directory on purpose: it catches anything that dies before `run.sh`
opens `run.log`, and putting it there means the log sync below picks it up with everything else.

`GH_TOKEN` is the only secret to pass, and it is deliberately **not** baked into the image. Note that
it is stripped from the environment of every model invocation — only the harness itself holds it, which
is what stops an implementer from pushing or closing an issue on its own.

## 6. Keep the logs

The logs live on the instance's root EBS volume, which is deleted when the instance is terminated. That
is the only copy of *why* anything happened: GitHub keeps the outcome — the commits, the closed issues —
while the diff each critic judged, the verdict it returned and the gate output that preceded it are all
in `logs/`. Roughly 400KB per issue, so the whole 44-issue backlog is about 15MB. Storing that is free;
losing it is not recoverable.

`deploy/log-sync.sh` copies it to S3 on a timer, host-side, alongside the container:

```bash
aws s3 mb s3://archunitdev-logs --region us-east-1        # once; keep it private

# edit deploy/s3-logs-policy.json to name the bucket, then:
aws iam put-role-policy --role-name ArchUnitDevLoop \
  --policy-name WriteLoopLogs --policy-document file://deploy/s3-logs-policy.json

nohup env S3_LOGS=s3://archunitdev-logs/loop LOGS=/home/ec2-user/logs \
  /harness/deploy/log-sync.sh > /home/ec2-user/log-sync.out 2>&1 &
```

**On a timer, not at the end**, because the failure being insured against is the instance dying
mid-run — an end-of-run copy is exactly the case that never executes. `SYNC_EVERY` defaults to 300s.
The first sync is fatal if it fails, so a bucket typo or a missing role policy surfaces at the start of
the night rather than at 04:00; after that a failure is a warning and it keeps trying. `SIGTERM` makes
it flush before exiting, so stopping the run loses nothing.

Each run goes under its own `RUN_ID` prefix (a UTC timestamp) so that re-running an issue cannot
silently overwrite the artifacts explaining what happened the first time. Set `RUN_ID` yourself to
resume into an existing prefix after a restart. The alternative — a flat prefix with bucket versioning
switched on — is equally good and needs no prefix bookkeeping.

The role policy is deliberately write-only: `PutObject` and a prefix-scoped `ListBucket`, which is all
`aws s3 sync` needs to upload. Pulling the logs back down is something you do from your own machine
with your own credentials:

```bash
aws s3 sync s3://archunitdev-logs/loop/20260814T220000Z ./logs-from-ec2
```

Note that `logs/skipped` and `logs/landed` are *state*, not output — the loop reads them to keep the
queue moving. They are synced with everything else, which is what makes a restore onto a fresh instance
pick up where the dead one left off. Be careful restoring `landed` next to a repo whose local commits
you did not also restore: the queue would skip work that no longer exists.

## Egress

If the instance has an egress policy, allow:

| Host | Why |
|---|---|
| `bedrock-runtime.*.amazonaws.com` | Inference. Wildcard, because the pinned model is a *global* inference profile and may route across regions. |
| `github.com`, `api.github.com` | `gh` reads and closes issues; `git` pushes. |
| `proxy.golang.org`, `sum.golang.org` | The gate runs `go build`, and the extractor depends on `golang.org/x/tools`. |
| `raw.githubusercontent.com`, `objects.githubusercontent.com` | **`docker build` only.** The `golangci-lint` install script and the release tarball it fetches. Not needed once the image exists. |

Not needed: `api.anthropic.com`. Inference goes to Bedrock.

If the build host and the run host are the same and the policy is applied at the instance level, the
two `githubusercontent.com` entries have to be open for the `docker build` and can be closed afterwards.
Build the image somewhere else if that is awkward — `golangci-lint` is pinned by version in the
`Dockerfile`, so the image is reproducible.

## Instance sizing

The loop is almost entirely waiting on the API. Two vCPUs is plenty — the only real work is `go build`
and `go test` in the gate. Disk matters more than CPU: the image is ~1.9GB, plus the Go module cache
and the logs, so give it 30GB.

Memory is the one thing worth checking rather than assuming. The gate runs `go test -race`, and the race
detector costs roughly 5–10× the memory of a plain test binary, on top of `golangci-lint`, which type-checks
the whole package graph and is the most memory-hungry step in the gate. 4GB is comfortable for a library
this size; 1GB is not, and the failure mode is the OOM killer taking out a step mid-gate, which reads as
a code defect in the log and sends the fixer after something that is not there.

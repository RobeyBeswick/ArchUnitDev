# Deploying the loop to EC2

The only thing that genuinely needs care is credentials: the loop runs for hours, and anything
short-lived dies partway through the night. An instance profile refreshes itself, so it is the only
option that survives a full run unattended. `run.sh` refuses an unbounded run on static credentials
rather than discovering the problem at 03:00.

Everything below assumes the Terraform stack in `deploy/terraform/`, which builds the whole thing:
network, instance, role, log bucket, image registry. The steps after it are the ones a human has to
do — push an image, put a token in Secrets Manager, decide that tonight is the night.

## 1. Provision it

```bash
cd deploy/terraform
terraform init
terraform plan          # 32 resources, nothing else touched
terraform apply
```

The outputs are the four things you need afterwards: the `aws ssm start-session` command, the ECR
repository URL, the log bucket, and the one-liner that creates the token secret.

**What it costs while it exists**, in round numbers per month: NAT gateway $32, the two interface
endpoints $15, a `t3.medium` left running $30, 30GB of gp3 $2.50. So a stack left up idle is about
$80/month and a stack up for one night is small change. `terraform destroy` when the batch is done —
see section 9, which has the one wrinkle.

**The GitHub token is not in Terraform**, on purpose: a secret in state is a secret in a git
repository. Terraform grants the role read access to a secret *by name*; you create the secret
yourself (section 4).

`bedrock-invoke-policy.json` and `s3-logs-policy.json` are the same two policies as standalone
documents, for attaching by hand to a role you made another way. Terraform inlines its own copies; if
you change one, change the other.

## 2. What "nothing public" means here

| Decision | Effect |
|---|---|
| Private subnet, `associate_public_ip_address = false` | The instance has no address reachable from the internet. Not a filtered one — none. |
| Security group with `ingress = []` | Nothing inbound, and written as an explicit empty list so a rule added by hand gets taken away again on the next apply. |
| NAT gateway for egress | One-way by construction: it has a public address, but a connection through it can only be opened from inside. |
| Session Manager instead of SSH | No key pair to lose, no listening port. The agent connects *outbound*; a session is an authenticated API call, logged in CloudTrail. |
| PrivateLink for Bedrock and Secrets Manager | The prompts, diffs and the token never traverse the public internet. |
| S3 gateway endpoint | Free, and does double duty: the log sync writes through it, and ECR keeps image layers in S3, so image pulls use it too. |
| Private ECR with scan-on-push | The image is pulled from inside the VPC rather than from a public registry. |
| Bucket: Block Public Access, `BucketOwnerEnforced`, AES256, versioning, TLS-only policy | ACLs are disabled outright, so "public-read on one object" is not a mistake available to be made. |
| IMDSv2 required, hop limit 2 | See below. |
| Encrypted EBS, `delete_on_termination = false` | The volume is the only copy of the night's commits under `NO_PUSH`. |

The **hop limit of 2** is the step that silently breaks everything if it is missed. EC2 defaults to 1,
and Docker's bridge network adds a hop — so the container cannot reach IMDS at all and the Bedrock
credentials never resolve. Terraform sets it to 2. Running the container with `--network host` avoids
the problem a different way.

Session Manager, SSM and the ECR *API* all reach AWS through the NAT gateway. Only the two services
carrying content worth keeping off the public internet got an endpoint each; an endpoint per service
would cost more per month than the rest of the plumbing is worth defending.

## 3. Build the image and push it

The image is not in the registry until you put it there, and **building on the instance is the
recommended path**, not the fallback. Two reasons, both learned the hard way: `proxy.golang.org` is
blocked on the network this repository is developed on but resolves fine from the instance, and a
laptop is likely the wrong architecture — an arm64 Mac produces an image a `t3.medium` cannot run, and
cross-building it under emulation takes about ten times as long as building it natively in the VPC.
The bootstrap clones this repository to `$HARNESS_DIR` for exactly this, so on the instance:

```bash
docker build -t archunitdev "$HARNESS_DIR"    # ~3 minutes, no --build-arg needed
```

That is all the loop needs — the image only ever has to exist on the one host that runs it. Push it to
ECR as well if you want a rebuilt instance to pull rather than rebuild:

```bash
REPO=${IMAGE%:*}
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "${REPO%%/*}"
docker tag archunitdev "$IMAGE" && docker push "$IMAGE"
```

Building from a laptop with a working network and the right architecture still works, with
`docker build --build-arg GOPROXY=direct -t archunitdev .` if the module proxy is blocked there.

One thing to know if you change the base image: **`apt` is pointed at HTTPS in the Dockerfile on
purpose.** The security group allows outbound 443 and nothing else, and Debian's default mirror URL is
`http://`, so an `apt-get` over port 80 does not fail fast — it hangs until apt gives up and takes the
build with it, two minutes in. `deb.debian.org` serves both, and the fix belongs in the image rather
than in the security group.

## 4. Get on the box, and give it the token

```bash
aws ssm start-session --target "$(terraform -chdir=deploy/terraform output -raw instance_id)"
```

Needs the Session Manager plugin locally (`brew install --cask session-manager-plugin`). If the
session is refused, the instance is still booting — the SSM agent registers a minute or two after the
instance reports running.

Create the token secret once, from your own machine. It has to be a **classic** PAT with the `repo`
scope, and that is not laziness about scoping down: the target repository is owned by another account
and reached as a collaborator, and a fine-grained token is scoped by *resource owner* — it can only
ever reach repositories owned by the account that issued it, so it cannot see this one at all. A
classic PAT carries the access its owner has. Give it the shortest expiry that covers the run.

```bash
# the account matters and there is no --account flag: identity comes from the credentials in use
aws sts get-caller-identity --query Account --output text     # expect <aws-account-id>
aws secretsmanager create-secret --region us-east-1 \
  --name archunitdev/gh-token --secret-string 'ghp_...'
```

Add the `workflow` scope only if a run will touch `.github/workflows/` — GitHub rejects such a push
without it. Nothing in the backlog needs it except issue #43.

On the instance, the bootstrap left the names in `/etc/profile.d/archunitdev.sh`, so:

```bash
export GH_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "$GH_TOKEN_SECRET" --query SecretString --output text)
```

`GH_TOKEN` is deliberately **not** baked into the image, and it is stripped from the environment of
every model invocation — only the harness itself holds it, which is what stops an implementer from
pushing or closing an issue on its own. Keep it that way: no token in `.git/config`, no
`~/.git-credentials`, no mounted key. Those are all files an implementer can read; an environment
variable the harness removes before it calls the model is not.

## 5. Check before committing to a night

```bash
docker run --rm -e GH_TOKEN -e PREFLIGHT_ONLY=1 \
  -v "$REPO_DIR:/work/repo" -v "$LOGS_DIR:/work/logs" "$IMAGE"
```

Costs nothing. You want `auth: Bedrock in us-east-1 as arn:aws:sts::…:assumed-role/archunitdev-loop/…`
and **no** static-credentials warning. Seeing `assumed-role/archunitdev-loop` is the proof that the
instance profile — not a leftover environment variable — is what answered.

It is *not* proof that inference works: that line comes from `sts get-caller-identity`, which resolves
credentials without calling Bedrock at all. The one assumption in this stack worth proving rather than
trusting is whether a regional PrivateLink endpoint can serve a *global* inference profile — the pinned
model is `global.anthropic.claude-opus-5`, which routes across regions server-side. One real call
settles it, for a fraction of a cent:

```bash
docker run --rm --entrypoint bash archunitdev -lc \
  'getent hosts bedrock-runtime.us-east-1.amazonaws.com; \
   claude --model global.anthropic.claude-opus-5 -p "Reply with exactly: OK"'
```

A `10.0.1.x` address for the hostname means DNS is resolving to the interface endpoint inside the
private subnet rather than to a public one, and a reply after it means the global profile is served
through it. Both hold as of 2026-08-14. If inference fails here but works with
`bedrock_vpc_endpoint = false`, that is the assumption breaking.

## 6. Run it

```bash
nohup docker run --rm \
  -e GH_TOKEN -e NO_PUSH=1 -e MAX_ISSUES=5 \
  -v "$REPO_DIR:/work/repo" \
  -v "$LOGS_DIR:/work/logs" \
  "$IMAGE" > "$LOGS_DIR/loop.out" 2>&1 &

tail -f "$LOGS_DIR/run.log"
```

`NO_PUSH=1` and a small `MAX_ISSUES` are the recommended shape for an unattended run: a batch of three
to five issues you can read in the morning, rather than a 35-deep chain of unreviewed commits.
Each issue is still recorded in `logs/landed`, so the queue advances; when you later push the batch,
the `Closes #N` trailers close the issues, and the next run prunes `landed` of anything now closed.

`loop.out` goes *inside* the log directory on purpose: it catches anything that dies before `run.sh`
opens `run.log`, and putting it there means the log sync picks it up with everything else.

The branch that is checked out is the branch the loop works on — `run.sh` commits to whatever `HEAD`
points at and never switches branches. A fresh clone is on `main`, which is what you want.

## 7. Keep the logs

The logs live on the instance's root EBS volume. That is the only copy of *why* anything happened:
GitHub keeps the outcome — the commits, the closed issues — while the diff each critic judged, the
verdict it returned and the gate output that preceded it are all in `logs/`. Roughly 400KB per issue,
so the whole backlog is about 15MB. Storing that is free; losing it is not recoverable.

`deploy/log-sync.sh` copies it to S3 on a timer, host-side, alongside the container. The role policy
and the bucket already exist from Terraform, so this is the whole of it:

```bash
nohup env S3_LOGS="$S3_LOGS" LOGS="$LOGS_DIR" \
  ~/ArchUnitDev/deploy/log-sync.sh > ~/log-sync.out 2>&1 &
```

**On a timer, not at the end**, because the failure being insured against is the instance dying
mid-run — an end-of-run copy is exactly the case that never executes. `SYNC_EVERY` defaults to 300s.
The first sync is fatal if it fails, so a bucket typo or a missing role policy surfaces at the start of
the night rather than at 04:00; after that a failure is a warning and it keeps trying. `SIGTERM` makes
it flush before exiting, so stopping the run loses nothing.

Each run goes under its own `RUN_ID` prefix (a UTC timestamp) so that re-running an issue cannot
silently overwrite the artifacts explaining what happened the first time. Set `RUN_ID` yourself to
resume into an existing prefix after a restart. Bucket versioning is on as well, so the two protections
are independent.

The role policy is deliberately write-only: `PutObject` and a prefix-scoped `ListBucket`, which is all
`aws s3 sync` needs to upload. No `GetObject` — pulling the logs back down is something you do from
your own machine with your own credentials:

```bash
aws s3 sync "s3://$(terraform -chdir=deploy/terraform output -raw log_bucket)/loop/20260814T220000Z" ./logs-from-ec2
```

Note that `logs/skipped` and `logs/landed` are *state*, not output — the loop reads them to keep the
queue moving. They are synced with everything else, which is what makes a restore onto a fresh instance
pick up where the dead one left off. Be careful restoring `landed` next to a repo whose local commits
you did not also restore: the queue would skip work that no longer exists.

## 8. Get the work back

Under `NO_PUSH=1` the commits exist only on the instance, and there is no way to `git fetch` *from* it —
that would need an inbound route, which is the thing this deployment does not have. Send the commits
out the way everything else leaves, as a file:

```bash
# on the instance
git -C "$REPO_DIR" bundle create "$LOGS_DIR/work.bundle" main
```

The next log sync carries it to S3. Then, on your machine:

```bash
aws s3 cp "s3://$(terraform -chdir=deploy/terraform output -raw log_bucket)/loop/<run-id>/work.bundle" ~/work.bundle
git -C ~/Projects/ArchUnitGo fetch ~/work.bundle main:from-ec2   # an absolute path; fetch resolves it as a remote
git -C ~/Projects/ArchUnitGo log --oneline main..from-ec2
```

A bundle is a complete, verifiable pack — `git fetch` checks that every commit's ancestry is present,
so a truncated upload fails loudly rather than importing half a night. Review, then push from your
laptop, which is where the credentials that can close issues live.

Mounting the root volume on another instance also works and is the fallback if the box died before it
could make a bundle. The volume survives termination by design.

## 9. Tear it down

```bash
terraform destroy
```

One wrinkle: because the root volume is set not to delete on termination, `destroy` leaves it behind as
an orphan Terraform no longer tracks — about $2.50/month until you remove it. That is the trade for not
losing a night's commits to a mistyped command. When the work is safely off it:

```bash
aws ec2 describe-volumes --filters Name=status,Values=available \
  --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table
aws ec2 delete-volume --volume-id vol-...
```

The log bucket and the ECR repository are both `force_destroy`, so `destroy` does remove those,
including the logs. Pull anything you want to keep first.

## Egress

The security group allows outbound 443 to anywhere and nothing else. Hostname allowlisting is not
something a security group can do — they take CIDRs — and doing it properly would mean AWS Network
Firewall at roughly $290/month, which is out of proportion to the risk on a box with no inbound route.
If you do apply a policy somewhere that can express hostnames, this is the list:

| Host | Why |
|---|---|
| `bedrock-runtime.*.amazonaws.com` | Inference. Wildcard, because the pinned model is a *global* inference profile and may route across regions. |
| `github.com`, `api.github.com` | `gh` reads and closes issues; `git` pushes. |
| `proxy.golang.org`, `sum.golang.org` | The gate runs `go build`, and the extractor depends on `golang.org/x/tools`. |
| `*.amazonaws.com` | SSM for the shell, ECR for the image, S3 for the logs, Secrets Manager for the token. |
| `raw.githubusercontent.com`, `objects.githubusercontent.com` | **`docker build` only.** The `golangci-lint` install script and the release tarball it fetches. Not needed once the image exists. |
| `deb.debian.org`, `claude.ai` | **`docker build` only.** The base image's packages and the Claude Code installer. The Dockerfile rewrites the Debian mirror to `https://` so this stays inside the 443 rule; see section 3. |

Not needed: `api.anthropic.com`. Inference goes to Bedrock.

## Instance sizing

The loop is almost entirely waiting on the API. Two vCPUs is plenty — the only real work is `go build`
and `go test` in the gate. Disk matters more than CPU: the image is ~1.5GB built on the instance
(~2.1GB for the arm64 build on a Mac), plus the Go module and build caches and the logs, so give it 30GB.

Memory is the one thing worth checking rather than assuming. The gate runs `go test -race`, and the race
detector costs roughly 5–10× the memory of a plain test binary, on top of `golangci-lint`, which type-checks
the whole package graph and is the most memory-hungry step in the gate. 4GB is comfortable for a library
this size; 1GB is not, and the failure mode is the OOM killer taking out a step mid-gate, which reads as
a code defect in the log and sends the fixer after something that is not there.

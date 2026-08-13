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

## 3. Check before committing to a night

```bash
docker run --rm -e GH_TOKEN -e PREFLIGHT_ONLY=1 \
  -v /home/ec2-user/ArchUnitGo:/work/repo -v /home/ec2-user/logs:/work/logs \
  archunitdev
```

Costs nothing. You want `auth: Bedrock in us-east-1 as arn:aws:sts::…:assumed-role/ArchUnitDevLoop/…`
and **no** static-credentials warning. Seeing `assumed-role/ArchUnitDevLoop` is the proof that the
instance profile — not a leftover environment variable — is what answered.

## 4. Run it

```bash
nohup docker run --rm \
  -e GH_TOKEN \
  -v /home/ec2-user/ArchUnitGo:/work/repo \
  -v /home/ec2-user/logs:/work/logs \
  archunitdev > loop.out 2>&1 &

tail -f /home/ec2-user/logs/run.log
```

`GH_TOKEN` is the only secret to pass, and it is deliberately **not** baked into the image. Note that
it is stripped from the environment of every model invocation — only the harness itself holds it, which
is what stops an implementer from pushing or closing an issue on its own.

## Egress

If the instance has an egress policy, allow:

| Host | Why |
|---|---|
| `bedrock-runtime.*.amazonaws.com` | Inference. Wildcard, because the pinned model is a *global* inference profile and may route across regions. |
| `github.com`, `api.github.com` | `gh` reads and closes issues; `git` pushes. |
| `proxy.golang.org`, `sum.golang.org` | The gate runs `go build`, and the extractor depends on `golang.org/x/tools`. |

Not needed: `api.anthropic.com`. Inference goes to Bedrock.

## Instance sizing

The loop is almost entirely waiting on the API. Two vCPUs is plenty — the only real work is `go build`
and `go test` in the gate. Disk matters more than CPU: the image is ~1.9GB, plus the Go module cache
and the logs, so give it 30GB.

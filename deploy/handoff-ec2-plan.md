# The EC2 deployment plan, as context for moving to Lambda microVMs

Written as a handoff. It states what the plan is today, what the loop actually needs from whatever
hosts it, and where Lambda's execution model collides with that. It does not propose a Lambda design —
that is the next agent's job.

> **Answered by `lambda-microvm-plan.md`.** Read §3 below as "where *Lambda functions* collide with the
> loop". Lambda MicroVMs is a different product: 8-hour maximum duration, writable persistent disk,
> IMDSv2 credentials, shell access. §1 of that plan walks these six items one by one; the first —
> the 15-minute ceiling — does not exist there. §2 is still accurate and still the thing to design
> against.

Sources: `deploy/README.md`, `deploy/bedrock-invoke-policy.json`, `README.md` (§Running it, §Knobs,
§Cost, §Known limits), `run.sh:108-137`, `Dockerfile`. Durations are measured from `logs/run.log`, not
estimated.

---

## 1. What the EC2 plan is

One long-lived EC2 instance in the Bedrock account (`AWS_ACCOUNT_ID` and `AWS_REGION` in
`deploy/local.env`), running the harness as a Docker container for hours, unattended, overnight.

**IAM.** A role `ArchUnitDevLoop` trusted by `ec2.amazonaws.com`, carrying
`deploy/bedrock-invoke-policy.json` — `bedrock:InvokeModel` and `InvokeModelWithResponseStream` on
`foundation-model/anthropic.*`, `inference-profile/*anthropic.*` and `application-inference-profile/*`,
all with `arn:aws:bedrock:*` regions. The region wildcard is deliberate: the pinned model is the
**global** inference profile `global.anthropic.claude-opus-5` and may route across regions. Attached to
the instance as an instance profile.

**Why an instance profile and not credentials.** This is the load-bearing decision of the whole plan.
The run lasts hours, so anything short-lived expires partway through and every invocation after that
fails. An instance profile refreshes itself. `run.sh:122-126` enforces this: if `AWS_SESSION_TOKEN` is
set and `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` is not, an unbounded run (`MAX_ISSUES=0`) is
**refused** rather than discovered failing at 03:00. `ALLOW_STATIC_CREDS=1` overrides.

**IMDS hop limit.** EC2 defaults `http-put-response-hop-limit` to 1 and Docker's bridge network adds a
hop, so the container cannot reach IMDS and credentials never resolve. The plan sets the limit to 2
(with `--http-tokens required`); `--network host` is the alternative.

**Secrets.** `GH_TOKEN` is the only one, passed by environment and deliberately not baked into the
image. `run.sh` strips `GH_TOKEN`/`GITHUB_TOKEN` from every model invocation with
`env -u GH_TOKEN -u GITHUB_TOKEN` — that is what stops an implementer pushing or closing an issue on
its own, so it must survive any port.

**Run shape.**
```bash
docker build -t archunitdev .
nohup docker run --rm -e GH_TOKEN \
  -v /home/ec2-user/ArchUnitGo:/work/repo \
  -v /home/ec2-user/logs:/work/logs \
  archunitdev > loop.out 2>&1 &
tail -f /home/ec2-user/logs/run.log
```
Preceded by the same command with `-e PREFLIGHT_ONLY=1`, which costs nothing and proves auth, tools,
repo, remote and queue. The signal to look for is
`auth: Bedrock … as arn:aws:sts::…:assumed-role/ArchUnitDevLoop/…` — seeing the role name is the proof
that the instance profile answered rather than a leftover environment variable.

**Egress allowlist.** `bedrock-runtime.*.amazonaws.com` (inference, wildcard for the global profile);
`github.com` + `api.github.com` (`gh` reads/closes issues, `git` pushes); `proxy.golang.org` +
`sum.golang.org` (the gate builds, and the extractor now depends on `golang.org/x/tools`);
`raw.githubusercontent.com` + `objects.githubusercontent.com` **for `docker build` only** (the pinned
golangci-lint install). `api.anthropic.com` is *not* needed — inference is Bedrock.

**Sizing, and why.** 2 vCPU is plenty (the loop is mostly waiting on the API). 30GB disk: 1.9GB image
plus the Go module cache plus logs. **4GB memory is the one requirement that is not padding** — the
gate runs `go test -race` (5–10× the memory of a plain test binary) and `golangci-lint`, which
type-checks the whole package graph. 1GB is not enough, and the failure mode is the OOM killer taking
out a gate step, which reads in the log as a code defect and sends the fixer after something that is
not there.

---

## 2. What the loop actually requires of a host

This is the part to design against; the EC2 specifics above are one satisfaction of it.

| Requirement | Detail |
|---|---|
| **Long single process** | `run.sh` is one bash process that iterates the queue. Per issue: 1 implementer, then a gate, then 3 concurrent critics, then a fixer per failed round, up to `MAX_ROUNDS=3`. 4–9 model invocations per issue. |
| **Per-invocation wall clock** | `TIMEOUT=30m` per `claude -p` call. Measured: issue #8's implementer alone ran **22 minutes** in one call. |
| **Per-issue wall clock** | Measured 8–30 min: #4 8.5m, #6 10m, #3 10.5m, #5 16m, #7 23.5m, **#8 30m**. Trending up as issues get larger; the backlog's biggest ("the LCOM family", "the six output formats") are called out as days of work. |
| **Writable git working tree** | It runs `git add -A`, commits with a `Closes #N` trailer, and pushes to the default branch. The tree must persist across issues — each issue builds on the last commit. |
| **Writable Go caches** | The gate builds, tests with `-race`, and cross-compiles for `windows/amd64` and `linux/386`. `GOPATH=/home/dev/go` in the image, with `golang.org/x/tools` pre-warmed (~110MB of modules plus compiled objects) so the first gate does not fetch and compile inside the implementer's clock. |
| **Persistent state, small** | Two files: `logs/skipped` (abandoned after `MAX_ROUNDS`) and `logs/landed` (implemented but left open, only under `NO_PUSH`). Both are excluded from the queue; `landed` is pruned at startup of any entry whose issue is no longer open. Everything else in `logs/` is output, one file per invocation. |
| **No state store beyond that** | The queue *is* "the lowest-numbered open issue" on GitHub; progress is the git history; the audit trail is the closed issues plus `NOTES.md`. **A killed run is resumed by running the script again** — this is the property any chunked design should lean on. |
| **Sequential by design** | Issues are in dependency order. Parallel implementers would conflict and build against a kernel that does not exist yet. Fan-out is not available as a way to fit a time budget. |
| **Concurrency within an issue** | The 3 critics run as concurrent subprocesses of the same script. |
| **Refresh-capable credentials** | See above; the guard at `run.sh:122` refuses an unbounded run without them. |
| **Tools on PATH** | `claude`, `gh`, `jq`, `aws`, the Go toolchain, `golangci-lint` >= v2.5.0. A missing `golangci-lint` or `.golangci.yml` is **fatal** in preflight, because either makes the gate go green while checking a fraction of what it claims — the architecture rules live in the target repo's `.golangci.yml` as `depguard` rules, not in `gate.sh`. |
| **Observability** | `logs/run.log`, one line per step, tailed live. There is no other progress signal. |

---

## 3. Where Lambda collides with that

Ranked by how much redesign each forces. The first one is a decision, not a detail.

1. **The 15-minute execution ceiling vs. a 22-minute implementer call.** This is the blocker, and it
   is not solved by decomposing the loop into one Lambda per model invocation: the *individual*
   `claude -p` call is what exceeds the limit. `TIMEOUT` would have to drop to ~13 minutes to fit,
   which is below what real implementer invocations on this backlog need — and a truncated implementer
   leaves a half-written package that the gate rejects, which `README.md` §Cost documents as costing
   more than it saves. `run.sh` passes `--no-session-persistence`, so there is currently no resume
   point *inside* an invocation to chunk against.
2. **Credentials read as static.** Lambda injects the execution role via `AWS_ACCESS_KEY_ID` /
   `SECRET_ACCESS_KEY` / `SESSION_TOKEN` environment variables, so `run.sh:122` sees
   `AWS_SESSION_TOKEN` set with no `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI` and refuses an unbounded
   run. Either set `ALLOW_STATIC_CREDS=1` or teach that guard about `AWS_LAMBDA_FUNCTION_NAME`. Inside
   a ≤15-minute invocation the expiry the guard exists to prevent cannot actually happen, so this is a
   guard to adjust, not a real constraint.
3. **Only `/tmp` is writable, and it does not persist.** The git working tree, the two state files and
   the Go build cache all need somewhere durable *between* invocations. Options are EFS (needs VPC) or
   rehydrating from git + S3 each time. Note the image's warm module cache lives at `/home/dev/go`,
   which is read-only under Lambda — `go build` wants to write lock files under `GOMODCACHE`, so that
   needs resolving (relocate or copy to `/tmp` on init), or the offline-build property is lost.
4. **Egress control means a VPC.** The plan's allowlist is written as an instance-level egress policy.
   Lambda gets AWS-managed internet by default with nothing to allowlist against; controlling it means
   VPC + NAT + security groups, with the cost and cold-start consequences that brings.
5. **Observability changes shape.** `tail -f logs/run.log` is how this loop has been watched all along.
   Under Lambda that becomes CloudWatch, and `run.log` is not a stream Lambda knows about.
6. **Memory and image size are fine.** Lambda goes to 10,240MB (≈6 vCPU) against a 4GB requirement,
   and the 10GB image limit against a 1.9GB image. Ephemeral `/tmp` also goes to 10GB. None of these
   are the problem.

## 4. What the next agent should decide first

Whether Lambda hosts **the loop** or only **triggers** it. The measured 22-minute single invocation
means the first reading needs an answer to "what happens to an implementer that needs longer than a
Lambda can run" before anything else is worth designing. The honest alternatives are a resumable
implementer (session persistence, which the harness currently disables), or Lambda as the scheduler in
front of something without a 15-minute ceiling — ECS Fargate or the EC2 plan above — with the microVM
isolation coming from Fargate rather than from Lambda.

# Running the loop on Lambda MicroVMs

The answer to the question `handoff-ec2-plan.md` §4 leaves open — "whether Lambda hosts the loop or only
triggers it" — is **both, and neither is a compromise**. Lambda MicroVMs hosts the loop; a plain Lambda
function triggers it.

The handoff's §3 reasons about **Lambda functions**. Lambda MicroVMs is a different product with a
different execution model, and every one of the six collisions listed there either disappears or shrinks
to a configuration line. Sources: the Lambda Developer Guide pages under *MicroVMs*
(`microvms-how-it-works`, `-images`, `-images-snapshots`, `-launching`, `-networking`, `-security`,
`-monitoring`, `-troubleshooting`, `-best-practices`, `-integrations-claude-managed-agents`), the Lambda
quotas page, the Lambda pricing page, and the
[aws-samples reference implementation](https://github.com/aws-samples/sample-lambda-microvm-claude-managed-agents)
for Claude Managed Agents, whose `Dockerfile`, `build-image.sh` and `worker.mjs` were read directly.

---

## 1. Why the blocker is gone

| Handoff §3 | On Lambda MicroVMs |
|---|---|
| **1. 15-minute ceiling vs. a 22-minute implementer** | `maximumDurationInSeconds` ranges **1–28,800 (8 hours)** and is documented as a hard, non-adjustable quota. A 22-minute `claude -p` call is unremarkable. `TIMEOUT=30m` stays as it is; no session persistence, no chunking inside an invocation, no truncated implementers. |
| **2. Credentials read as static** | Credentials arrive through **IMDSv2**, not environment variables ("IAM through IMDSv2 — uses short-term, least privilege credentials"). `run.sh:122` sees no `AWS_SESSION_TOKEN` and the guard passes untouched — the same property the EC2 instance profile was chosen for, and for the same reason. Also no Docker bridge, so no `--http-put-response-hop-limit 2`. **Verify with `PREFLIGHT_ONLY=1`**; the proof is the same as on EC2, an `assumed-role/…` ARN in the auth line. |
| **3. Only `/tmp` is writable, nothing persists** | The MicroVM root filesystem is writable, with **8/16/32 GB** of disk depending on baseline size. `GOMODCACHE` at `/home/dev/go` stays where it is and stays warm — the offline-build property survives intact. Disk *does* persist across suspend/resume, and does *not* survive terminate; §6 covers that. |
| **4. Egress control means a VPC** | Still true, and unchanged in substance: `INTERNET_EGRESS` is open internet; restricting it means a customer-managed VPC egress connector with subnets and security groups. §5.4 is honest about what that can and cannot enforce. |
| **5. Observability changes shape** | stdout/stderr go to CloudWatch Logs (`/aws/lambda/microvms/<image-name>`, stream = MicroVM ID) *if an execution role is attached*, and there is an interactive **shell** into a running MicroVM. `tail -f run.log` becomes `aws logs tail --follow`, plus a real shell when that is not enough. |
| **6. Memory and image size are fine** | Still fine, with a caveat that replaces it: sizes are **fixed rungs**, not arbitrary, and vCPU is welded to memory at 2 GB per vCPU. See §5.2. |

Two new constraints the handoff could not have known about, both real:

- **ARM64 only.** "Lambda MicroVMs support the ARM64 (AWS Graviton) architecture", and MicroVM pricing is
  quoted for ARM/Graviton. The image has to be rebuilt for `linux/arm64`. This is mechanical — verified
  that all three pinned tools ship `linux-arm64` assets (`golangci-lint-2.12.2-linux-arm64.tar.gz`,
  `gh_2.65.0_linux_arm64.tar.gz`, and `claude.ai/install.sh` resolves `arm64|aarch64` → `linux-arm64`),
  `golang:1-bookworm` is multi-arch, and `go test -race` supports `linux/arm64`. The gate's
  cross-compiles (`windows/amd64`, `linux/386`) are unaffected — they are cross-compiles.
- **The image is a snapshot of a *running* application, and MicroVMs are request-driven.** This is the
  one genuine collision, and §3 is about it.

---

## 2. The execution model, stated precisely

Worth having in one place, because the design in §4 is a consequence of it and nothing else.

- A **MicroVM image** is built by Lambda: you upload a zip containing a `Dockerfile` at its root to S3,
  call `create-microvm-image` with a Lambda-published `--base-image-arn`, and Lambda runs your
  `Dockerfile` inside a fresh MicroVM, starts your app via `ENTRYPOINT`/`CMD`, waits for your `/ready`
  hook to return HTTP 200, and then **captures a Firecracker snapshot of disk and memory, including all
  running processes**.
- `run-microvm` restores that snapshot. Startup is sub-second to single-digit seconds because nothing
  boots — the processes are already running, resumed mid-flight.
- Every MicroVM gets a dedicated HTTPS endpoint. All access requires a JWE token from
  `create-microvm-auth-token`; there is no unauthenticated path. Requests route to port 8080 unless
  `X-aws-proxy-port` says otherwise.
- Lambda POSTs **lifecycle hooks** to your app on a port you declare: `/ready` and `/validate` at build
  time, `/run`, `/resume`, `/suspend`, `/terminate` at run time, all under
  `/aws/lambda-microvms/runtime/v1/`. **Your app receives no external traffic until `/run` returns 200**,
  and "if your `/run` hook fails or times out, the MicroVM may transition directly to `TERMINATING`
  without ever reaching `RUNNING`".
- `runHookPayload` (max 16 KB, per-MicroVM) is delivered to `/run` as
  `{"microvmId": "...", "runHookPayload": "..."}`. Environment variables, by contrast, are set at
  **image build time and are therefore identical in every MicroVM built from that image** — which
  decides where `GH_TOKEN` can and cannot live.
- The **idle policy** suspends a MicroVM after `maxIdleDurationSeconds` without *endpoint traffic*.
  Terminate is triggered by `terminate-microvm`, by `suspendedDurationSeconds` elapsing while suspended,
  or by `maximumDurationInSeconds` elapsing. Suspended VMs pay snapshot storage, not compute; terminated
  VMs pay nothing.

---

## 3. The one real collision, and the shape it forces

**`run.sh` is a batch process. Lambda MicroVMs wants a long-lived server that answers HTTP hooks.**

`ENTRYPOINT ["/harness/run.sh"]` cannot survive contact with this model. Three separate reasons, each
sufficient:

1. The image build starts the entrypoint and snapshots it. `run.sh` as the entrypoint would start
   **spending money at image build time**, against whatever the queue was that afternoon, and the
   resulting snapshot would contain a half-finished implementer — replayed identically by every MicroVM
   launched from that image.
2. There would be nothing to answer `/ready`, so the build could never complete, and nothing to answer
   `/run`, so the MicroVM would terminate on arrival.
3. Per-run configuration (`GH_TOKEN`, `MAX_ISSUES`, `NO_PUSH`, the target repo) can only arrive through
   `runHookPayload`, which is delivered to an HTTP endpoint. There is no other channel.

So the entrypoint becomes a **supervisor**: a small HTTP server that owns the hooks and treats `run.sh`
as a child process it starts on `/run`. This is exactly the shape the aws-samples worker uses — an
`EnvironmentWorker` HTTP server on port 9000 that acknowledges `/run`, does the work detached, and calls
`terminate-microvm` on itself when finished.

Three things fall out of it, and all three are improvements rather than costs:

- **`/ready` is a build-time preflight.** The checks that `run.sh` currently makes fatal at 03:00 — a
  missing `golangci-lint`, a missing Go toolchain, a missing `claude` — can be made fatal at
  **image build** instead, where the consequence is `CREATION_FAILED` and a line in
  `/aws/lambda/microvms/<image-name>` rather than a night spent going green while checking a fraction of
  what it claims to.
- **`/run` is the runtime preflight.** Clone, `gh auth status`, `aws sts get-caller-identity`,
  `PREFLIGHT_ONLY=1` — all of it inside the hook, with `runTimeoutInSeconds` bounding it. A bad token or
  an unreachable remote fails the hook, which terminates the MicroVM immediately and loudly, which is
  precisely what preflight exists to do.
- **`/terminate` is the last-words hook.** It is the only place that can push a work-in-progress branch
  and flush `logs/` to S3 before an 8-hour ceiling takes the disk with it. See §6.

**Snapshot safety.** Because the supervisor is the only process alive when the snapshot is taken, the
uniqueness hazard the docs warn about mostly does not apply: `claude`, `go`, `git` and `gh` all start
*after* `/run`, and freshly-started processes seed from `/dev/urandom`, which the docs state explicitly
"maintains randomness when used with MicroVM image snapshots". The supervisor must therefore hold no
long-lived TLS connection and generate no secret or ID at build time. Keep it boring: a stdlib HTTP
server, plaintext, no client sockets. (The AWS guidance to prefer
`public.ecr.aws/lambda/microvms:al2023-minimal` for its snapshot-patched OpenSSL is aimed at applications
that are *running* across the snapshot boundary. See §5.1 for why the recommendation here is still to keep
`golang:1-bookworm`, and when to reconsider.)

---

## 4. The architecture

```
EventBridge Scheduler (nightly)
        │
        ▼
launcher Lambda function ── reads image ARN + config, calls RunMicrovm
        │                    (a function is the right tool here: seconds of work)
        ▼
MicroVM  (4 GB / 2 vCPU baseline, 8h max, INTERNET_EGRESS, SHELL_INGRESS)
        │
   supervisor.py  (PID 1, port 9000, snapshotted running)
        │  /ready     → tool checks            → image build gate
        │  /validate  → tool checks on restore → build gate + snapshot warming
        │  /run       → fetch GH_TOKEN from Secrets Manager,
        │               git clone → /work/repo, PREFLIGHT_ONLY=1,
        │               spawn bootstrap detached, return 200
        │  /status    → tail of run.log         → the tail -f replacement
        │  /terminate → push WIP branch, sync logs/ to S3
        ▼
   bootstrap.sh ──▶ run.sh  (unchanged loop: implementer → gate → 3 critics → fixer)
        │            stdout/stderr inherited by the supervisor → CloudWatch Logs
        ▼
   terminate-microvm (self), when the queue empties or the deadline is reached
```

State lives where it already lives: the queue is GitHub, progress is the git history, the audit trail is
the closed issues plus `NOTES.md`. §6 is about closing the two small gaps in that claim so a MicroVM needs
no durable disk at all.

---

## 5. Decisions, with reasons

### 5.1 Base image: keep `golang:1-bookworm`, on arm64

The `Dockerfile` is allowed to `FROM` any Linux image that is arch-compatible, reachable from the build
infrastructure, and snapshot-compatible. The pull to rewrite it onto `al2023-minimal` should be resisted:
the existing image's value is the pinned toolchain and the **warm, compiled `golang.org/x/tools` module
cache**, and porting `apt` → `dnf` plus a hand-rolled Go install risks exactly the property preflight was
written to protect. The snapshot-compatibility argument for `al2023-minimal` is about OpenSSL state in a
process that is live across the snapshot; here that process is a stdlib HTTP server that touches no TLS.

Reconsider if `/validate` misbehaves in a way that points at snapshot state, or if you decide the
supervisor needs to hold a TLS client connection.

Changes to the `Dockerfile`:

- Build for `linux/arm64` (`docker buildx build --platform linux/arm64`, or just build it in the
  MicroVM image build, which is arm64 already). `TARGETARCH` already parameterises the `gh` download;
  the `golangci-lint` installer and `claude.ai/install.sh` both resolve arch themselves.
- Replace `ENTRYPOINT ["/harness/run.sh"]` with `ENTRYPOINT ["python3", "/harness/deploy/microvm/supervisor.py"]`.
- Drop `ENV REPO=/work/repo LOGS=/work/logs` in favour of the supervisor passing them, and `mkdir` both
  in the image so the clone target exists.
- Keep `USER dev`. Claude Code refuses `--dangerously-skip-permissions` as root and the loop cannot
  afford a permission prompt; nothing about MicroVMs changes that.
- Do **not** put `GH_TOKEN` in `environmentVariables`. Image-level env vars are shared by every MicroVM
  built from the image, which is a strictly worse place for a secret than the current one.
- Note for the `claude` install step: the installer treats exit code 137 as OOM. If the image build fails
  there, the baseline size is the thing to look at.

### 5.2 Size: 4 GB / 2 vCPU baseline

The rungs are fixed and vCPU is tied to memory at 2 GB per vCPU:

| Baseline | Peak (automatic, 4×) | Max disk |
|---|---|---|
| 2 GB / 1 vCPU (default) | 8 GB / 4 vCPU | 8 GB |
| **4 GB / 2 vCPU** | **16 GB / 8 vCPU** | **16 GB** |
| 8 GB / 4 vCPU | 32 GB / 16 vCPU | 32 GB |

4 GB is chosen for the reason the EC2 plan chose it — `go test -race` at 5–10× a plain test binary plus
`golangci-lint` type-checking the whole package graph, where the failure mode is the OOM killer taking out
a gate step and the log reading as a code defect. The default 2 GB rung would rely on automatic peak
scaling to cover the gate, and its **8 GB disk** is the tighter problem: a ~2 GB image plus the module and
build caches plus a clone plus a night of logs does not leave much. 16 GB of disk removes the question.

Peak is billed only for the duration actually consumed above baseline, so paying for 4 GB baseline instead
of 2 GB costs about a dollar a night (§8) and buys determinism in the one step whose failure is misdiagnosed
as a code defect.

### 5.3 Idle policy: **the loop must never be suspended**

This is the sharpest footgun in the whole design. Suspension is triggered by absence of *endpoint*
traffic, and the harness generates none — it talks to Bedrock and GitHub, outbound. A sample-default
`maxIdleDurationSeconds: 300` would suspend the MicroVM roughly five minutes into the first implementer
call. The docs say it plainly: "For asynchronous applications that do not actively send or receive traffic
through the endpoint, disable automatic suspension or configure a suitable idle duration."

```
--idle-policy '{"autoResumeEnabled":false,"maxIdleDurationSeconds":28800,"suspendedDurationSeconds":0}'
--maximum-duration-in-seconds 28800
```

`maxIdleDurationSeconds` at its 28,800 maximum equals `maximumDurationInSeconds`, so idle suspension can
never fire before the hard ceiling does. `autoResumeEnabled:false` and `suspendedDurationSeconds:0` mean a
suspend, if one somehow happens, terminates rather than silently parking a VM that pays storage. The
Claude Managed Agents page recommends the same pair for per-session MicroVMs.

Do not rely on suspend/resume as a way to stretch past 8 hours: `maximumDurationInSeconds` counts running
*and* suspended time, and a resumed `claude` process would come back with dead TLS connections and a
`timeout` alarm whose relationship to wall clock across a checkpoint is not something to bet a night on.

### 5.4 Networking: `INTERNET_EGRESS` first, and be honest about the allowlist

Start with the Lambda-managed connectors:

```
--ingress-network-connectors arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:SHELL_INGRESS
--egress-network-connectors  arn:aws:lambda:us-east-1:aws:network-connector:aws-network-connector:INTERNET_EGRESS
```

`SHELL_INGRESS` is required for `create-microvm-shell-auth-token` — without it that call fails with
`ValidationException`, and shell access is the debugging tool that replaces "ssh to the instance". Add
`ALL_INGRESS` if you want the `/status` endpoint reachable; use `NO_INGRESS` for a fully headless run —
but **verify first that lifecycle hooks are still delivered under `NO_INGRESS`**, which the docs do not
state either way. Hooks arrive from Lambda rather than from the internet, so they should be unaffected;
that is an inference, not a documented guarantee.

On the egress allowlist, the honest position: the EC2 plan's table is a list of *hostnames*
(`bedrock-runtime.*.amazonaws.com`, `github.com`, `proxy.golang.org`, …). A VPC egress connector gives
security groups and NACLs, which filter on **IP and port**, not names — so the allowlist does not port
directly, and it would not have ported to an EC2 security group either. If the allowlist is a real
requirement rather than an aspiration, it needs a VPC egress connector plus a NAT gateway plus AWS Network
Firewall with domain rules, or an explicit HTTP proxy the harness is pointed at. That is a meaningful
amount of machinery, a `SubnetOutOfIPAddresses`-class failure mode, and a NAT bill. Recommendation: run
with `INTERNET_EGRESS` and keep the allowlist as documentation of intent, unless someone names the threat
it is defending against. The MicroVM's Firecracker boundary is doing the isolation work that
`--dangerously-skip-permissions` needs, and doing it better than a container on a shared instance did.

The two `githubusercontent.com` hosts the EC2 plan needed for `docker build` are now needed by **Lambda's
build infrastructure**, not by anything you control — one more reason not to invest in a build-time egress
story.

### 5.5 IAM: three roles, none of them an instance profile

| Role | Trusted by | Needs |
|---|---|---|
| **Build role** | `lambda.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`) | `s3:GetObject` on the artifact bucket; `logs:CreateLogGroup`/`CreateLogStream`/`PutLogEvents`. Without it there are no build logs, which makes a failed build unreadable. |
| **Execution role** | `lambda.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`) | `deploy/bedrock-invoke-policy.json` **unchanged** — the region wildcard is still needed for the global inference profile; the logs trio, or stdout/stderr never reach CloudWatch; `secretsmanager:GetSecretValue` on the one `GH_TOKEN` secret ARN; `lambda:TerminateMicrovm` on `arn:aws:lambda:*:<acct>:microvm:*` so the VM can end its own billing; optionally `s3:PutObject` on a logs prefix. |
| **Launcher function role** | `lambda.amazonaws.com` | `lambda:RunMicrovm`, `lambda:GetMicrovm`, `lambda:ListMicrovms`, `iam:PassRole` for the execution role. |

The load-bearing decision from the EC2 plan carries over unchanged and for the same reason: the run lasts
hours, so credentials must refresh themselves. Here that is the execution role via IMDSv2 instead of an
instance profile via IMDS. `run.sh:122` should need **no** change and `ALLOW_STATIC_CREDS` should **not**
be set — if the guard fires, that is information, not an inconvenience, and the fix is to teach the guard
about MicroVMs rather than to silence it.

### 5.6 The secret: Secrets Manager by reference

`GH_TOKEN` cannot be an image environment variable (shared across every MicroVM from that image) and
should not be a `runHookPayload` value (it lands in the `RunMicrovm` call, hence in CloudTrail data events
if enabled, and in the launcher's memory). Use the pattern the AWS sample uses: the launcher passes the
**secret's name or ARN** in `runHookPayload`, and the MicroVM's execution role reads the value at runtime.

`run.sh` already strips `GH_TOKEN`/`GITHUB_TOKEN` from every model invocation with
`env -u GH_TOKEN -u GITHUB_TOKEN`. That is what stops an implementer pushing or closing an issue on its
own, it is unaffected by any of this, and it must survive the port — the supervisor must not re-export the
token into the child in some other way, and must not log it.

### 5.7 Observability

| EC2 | MicroVM |
|---|---|
| `tail -f logs/run.log` | `aws logs tail /aws/lambda/microvms/archunitdev-loop --follow` — `say`'s narration reaches stdout, which the execution role forwards. Requires that `bootstrap.sh` be spawned with the supervisor's stdout/stderr **inherited**, not redirected to a file. |
| `docker exec` / ssh | `create-microvm-shell-auth-token`, then Console → Connect, or `ctr task ls` / `ctr task exec -t --exec-id shell <id> /bin/sh`. Requires `SHELL_INGRESS`. |
| `logs/N-implement.json`, per-invocation envelopes, `total_cost_usd` | Ephemeral. Sync `logs/` to S3 at the end of the run and from `/terminate`, or the cost accounting and the per-invocation detail die with the VM. |
| — | `get-microvm`'s `terminationMessage` / `stateReason` on an unexpected termination, and CloudTrail (`RunMicrovm` etc. are **data** events and are off by default). |

---

## 6. The 8-hour ceiling: what it actually costs

Measured per-issue wall clock is 8–30 minutes and trending up (#4 8.5m, #6 10m, #3 10.5m, #5 16m,
#7 23.5m, #8 30m). Eight hours is therefore something like 16 issues at the current rate and fewer as the
backlog's larger items arrive — a whole night's work, but not the whole 44-issue backlog. The queue is
GitHub, so sessions chain across nights with no coordination: tomorrow's MicroVM starts from the issues
still open.

The ceiling has one sharp edge and it needs closing. **The disk does not survive termination**, and
`maximumDurationInSeconds` terminates whatever is running. On EC2 a killed run left the working tree on
disk; here it leaves nothing. Concretely, a session that hits 8 hours mid-implementer loses that
implementer's work — up to half an hour of model spend — and the issue is re-implemented from scratch
tomorrow.

Two changes, in order of value:

1. **A deadline-aware stop in `run.sh`.** A new knob (`DEADLINE_EPOCH`, set by the supervisor from
   `maximumDurationInSeconds` at `/run`) checked at the top of the queue loop, next to the existing
   `MAX_ISSUES` and circuit-breaker checks around `run.sh:254`. If the remaining wall clock is less than a
   floor — 35 minutes is the measured worst case plus margin — stop cleanly and say so, rather than
   starting an issue that cannot finish. This is the honest analogue of `MAX_ISSUES` for a host with a
   ceiling, and it composes with the existing "a killed run is resumed by running the script again"
   property rather than fighting it.
2. **A `/terminate` hook that pushes what exists.** Belt to the deadline's braces, for the case where an
   issue overruns anyway: commit the tree to `wip/session-<microvmId>`, push it, sync `logs/` to S3. The
   docs place `/terminate` before resources are released precisely for this.

### Two pieces of state, and how to stop needing them

`README.md` claims there is no state store. That is true modulo two files in `LOGS`, and on an ephemeral
disk the claim has to become literally true:

- **`skipped`** — issues abandoned after `MAX_ROUNDS`. It is already mirrored remotely:
  `run.sh:424` does `gh issue edit "$N" --add-label needs-human`. Filter the queue at `run.sh:282` on that
  label and the file becomes a within-session convenience rather than durable state. That makes the label
  application **load-bearing**, so it must stop being best-effort (`>/dev/null 2>&1 ||`) — if the label
  fails to apply, tomorrow's session re-attempts an issue a human has been asked to look at.
- **`landed`** — only written under `NO_PUSH`. Which surfaces a real trap: **`README.md` recommends
  `NO_PUSH=1` for the first run, and on a MicroVM that destroys the work.** The commits are local to a
  disk that will not exist. The first-run advice has to change: point the loop at a scratch fork or a
  throwaway branch and let it push, or run the first issue in Docker on a laptop exactly as the README
  already documents. Whatever the plan does here, `NO_PUSH` on a MicroVM should warn loudly.

With both of those done, a MicroVM needs no durable disk and no S3 state — only the S3 log sync, which is
output rather than state.

---

## 7. What changes in this repo

Small, and mostly additive. Nothing in the loop, the gate, the prompts or the critics changes.

**New: `deploy/microvm/supervisor.py`** — stdlib `http.server` on port 9000.

| Route | Behaviour |
|---|---|
| `POST …/ready` | `command -v` + `--version` for `claude`, `gh`, `jq`, `aws`, `go`, `golangci-lint` (≥ v2.5.0). 200 on success, 503 while still starting. A missing linter now fails the **image build**. |
| `POST …/validate` | The same checks on a restored MicroVM. Also the documented place to run mock work so Lambda can prefetch the snapshot regions that actually get touched. |
| `POST …/run` | Parse `{microvmId, runHookPayload}`. Read `GH_TOKEN` from the Secrets Manager ARN in the payload. `git clone` → `/work/repo`, `git config --add safe.directory`, wire the push credential. Set `DEADLINE_EPOCH`. Run `PREFLIGHT_ONLY=1 run.sh`. Spawn `bootstrap.sh` detached with stdout/stderr inherited. Return 200. Non-200 here terminates the MicroVM, which is the point. |
| `GET /status` | Last N lines of `run.log` plus the current issue. Port 8080. |
| `POST …/suspend`, `…/resume` | Log loudly and return 200. Reaching either means the idle policy is wrong (§5.3). |
| `POST …/terminate` | Push `wip/session-<microvmId>` if the tree is dirty; sync `logs/` to S3. |

**New: `deploy/microvm/bootstrap.sh`** — `run.sh` wrapper: run the loop, sync `logs/` to S3, then
`aws lambda-microvms terminate-microvm --microvm-identifier "$MICROVM_ID"` so the VM stops billing the
moment the queue empties rather than idling to the ceiling.

**New: `deploy/microvm/build-image.sh`** — zip `Dockerfile` + harness → S3 → `create-microvm-image`.
The `--hooks` shape, taken from the working AWS sample:

```bash
aws lambda-microvms create-microvm-image \
  --name archunitdev-loop \
  --code-artifact "uri=s3://$BUCKET/$KEY" \
  --base-image-arn "$(aws lambda-microvms list-managed-microvm-images --query 'items[0].imageArn' --output text)" \
  --build-role-arn "$BUILD_ROLE_ARN" \
  --memory 4096 \
  --hooks '{"port":9000,
            "microvmImageHooks":{"ready":"ENABLED","readyTimeoutInSeconds":600,
                                 "validate":"ENABLED","validateTimeoutInSeconds":300},
            "microvmHooks":{"run":"ENABLED","runTimeoutInSeconds":300,
                            "suspend":"ENABLED","suspendTimeoutInSeconds":30,
                            "resume":"ENABLED","resumeTimeoutInSeconds":30,
                            "terminate":"ENABLED","terminateTimeoutInSeconds":300}}'
```

Confirm `--memory`'s name and unit against `aws lambda-microvms create-microvm-image help` before
trusting it — the guide says the baseline is set "by using the `memory` parameter when creating your
MicroVM image" but does not give the unit, and the AWS sample omits it and takes the 2 GB default. The
`readyTimeoutInSeconds` of 600 is deliberate headroom over the sample's 300: the `/ready` checks include
`golangci-lint --version`, which is not instant on a cold page cache.

**New: `deploy/microvm/launcher.py` + `template.yaml`** — EventBridge Scheduler → Lambda function →
`RunMicrovm`. A function is the right tool for this half: seconds of work, and the 15-minute ceiling that
was fatal for the loop is irrelevant for a launcher. Keep `run-microvm`'s `ThrottlingException` in mind
(`RunMicrovm` is 5 TPS) — irrelevant at one VM a night, but the retry-with-backoff idiom is in the docs.

**Changed: `Dockerfile`** — §5.1.

**Changed: `run.sh`** — three edits, all small:

| Where | Change |
|---|---|
| ~`:254` | `DEADLINE_EPOCH` check in the queue loop: stop cleanly if less than `DEADLINE_FLOOR` (default 35m) remains. Sits naturally beside `MAX_ISSUES` and the two circuit breakers, and shares their argument — stopping is recoverable, a queue of spurious abandonments is not. |
| `:282` | Exclude `needs-human` from the queue so `skipped` stops being durable state. |
| `:424` | Make the `needs-human` label application non-best-effort now that the queue depends on it. |
| `:122` | **Expected to need nothing.** Only touch it if `PREFLIGHT_ONLY=1` on a real MicroVM shows env-var credentials. |

**Changed: `test/loop_test.sh`** — the repo's own argument is that the paths that matter most are the ones
a real run almost never takes, so the new paths need stubbed scenarios:

| Scenario | What it pins down |
|---|---|
| `deadline` | With `DEADLINE_EPOCH` inside the floor, the loop stops before starting an issue, says why, and touches nothing remote. Outside the floor, it proceeds. |
| `needs_human_queue` | An open issue labelled `needs-human` is excluded from the queue with no `skipped` file present; and the label failing to apply is now an error rather than a shrug. |

The supervisor's hooks want a test too — a scenario that POSTs `/ready`, `/run` and `/terminate` against
stubbed `claude`, `gh` and `aws` and asserts the status codes and that `GH_TOKEN` never appears in a child
environment or a log line.

---

## 8. Cost

Compute, us-east-1, ARM: `$0.0000276944` per vCPU-second and `$0.0000036667` per GB-second at baseline;
above baseline you pay only for the duration actually consumed.

| | Per hour | Per 8-hour session |
|---|---|---|
| 4 GB / 2 vCPU baseline | $0.252 | **$2.02** |
| 2 GB / 1 vCPU baseline | $0.126 | $1.01 |

Peak bursts are trivially small — the gate bursting to 8 GB / 4 vCPU for two minutes adds under a cent.
Snapshot read at launch is `$0.00155`/GB (well under a cent for a ~2 GB image); image storage is
`$0.08`/GB-month with a one-week minimum retention, so a couple of image versions is a few tens of cents a
month; suspended storage is the same rate and should never apply here (§5.3).

For comparison, an always-on `t4g.medium` is roughly an order of magnitude less per hour — but it is
always on, and this is not. Either number is noise against the loop's actual cost: a few dollars an issue
across a 44-issue backlog, which is the only line in the bill worth optimising, and the reason
`README.md` §Cost argues against per-invocation spend caps. **Cost is not the reason to choose either
host.** The reasons are that there is no instance to patch, own or forget to stop; that a Firecracker
boundary is a better place to run `--dangerously-skip-permissions` than a container on a shared box; and
that billing ends when the queue empties.

Set `--maximum-duration-in-seconds` on every launch regardless. It is the only backstop against a wedged
supervisor paying $0.25/hour until someone notices.

---

## 9. Order of work

Each step ends in something checkable, and the first three cost nothing.

1. **Upgrade tooling.** The `lambda-microvms` API is absent from `aws-cli/2.34.30` (verified locally:
   `Found invalid choice 'lambda-microvms'`). Upgrade the CLI and confirm
   `aws lambda-microvms list-managed-microvm-images` returns a base image ARN in `us-east-1`. The launcher
   needs a `boto3` new enough to have the `lambda-microvms` client; the AWS sample bundles
   `boto3-1.43.34` wheels into its deployment package, which is the tell that this is not yet the ambient
   version.
2. **Port the image to arm64 and prove it locally.** `docker buildx build --platform linux/arm64`, then
   run `./test/loop_test.sh` and `PREFLIGHT_ONLY=1` inside it on the existing entrypoint. This isolates
   "does the toolchain work on arm64" from every MicroVM question. Free.
3. **Write the supervisor and test it under Docker**, still with no AWS involved: POST the hook paths by
   hand, assert the status codes, assert `GH_TOKEN` hygiene. Free.
4. **Roles, bucket, secret.** Build role, execution role (the existing `bedrock-invoke-policy.json` plus
   logs, Secrets Manager, `TerminateMicrovm`), artifact bucket, `GH_TOKEN` in Secrets Manager.
5. **First image build.** `create-microvm-image` and watch `/aws/lambda/microvms/archunitdev-loop`. The
   check is that `/ready` gating works: deliberately break `golangci-lint` in the `Dockerfile` once and
   confirm the build fails rather than producing an image that would go green while checking a fraction of
   what it claims to.
6. **First MicroVM, preflight only.** `run-microvm` with `SHELL_INGRESS`, a `runHookPayload` carrying
   `PREFLIGHT_ONLY=1`, and the idle policy from §5.3. The signal to look for is the same one the EC2 plan
   named: `auth: Bedrock in us-east-1 as arn:aws:sts::…:assumed-role/…` — seeing a role name is the proof
   that IMDSv2 answered rather than a leftover environment variable — and **no** static-credentials
   warning. Then shell in and confirm `GOMODCACHE` is warm and writable. Costs nothing but a few minutes
   of VM.
7. **One issue.** `MAX_ISSUES=1`, pushing, against a scratch fork. This is the step that tells you whether
   the commit and push path works from a fresh clone with a Secrets Manager token — the one part of the
   loop that was never exercised on EC2, because a human had cloned the repo and configured its remote by
   hand.
8. **A bounded night.** `MAX_ISSUES=3`, `maximumDurationInSeconds` at 2 hours, and watch
   `aws logs tail --follow`. Confirm the deadline stop fires cleanly rather than the ceiling killing an
   implementer.
9. **Unbounded, scheduled.** EventBridge Scheduler nightly, `MAX_ISSUES=0`, 8 hours,
   `MAX_CONSECUTIVE_ABANDONS` left at its default.

---

## 10. Open questions, honestly labelled

Things the design depends on that the documentation does not settle. None of them look likely to change
the shape, but each should be answered before step 9 rather than at 03:00.

1. **Credential delivery mechanism.** "IAM through IMDSv2" is from the Claude Managed Agents page, not
   from `microvms-security`, which does not say how credentials reach the guest at all. If they arrive as
   environment variables instead, `run.sh:122` refuses an unbounded run and the fix is to teach it about
   MicroVMs. Step 6 answers this.
2. **Whether hooks are delivered under `NO_INGRESS`.** Inferred, not documented. Step 6 answers it if you
   try `NO_INGRESS`; the safe path is `SHELL_INGRESS`, which you want anyway.
3. **`--memory`'s exact name, unit and whether it is an image-level or run-level parameter.** The guide
   says image-level; `aws lambda-microvms create-microvm-image help` settles it.
4. **Whether 4 GB baseline is genuinely enough with peak scaling, or whether the gate wants the 8 GB
   rung.** The EC2 evidence is that 4 GB is comfortable for a library this size; MicroVMs adds automatic
   headroom to 16 GB. The way to find out is `gate.sh` on the largest issue with a shell open.
5. **How quotas behave on a new account.** "New AWS accounts have reduced concurrency and memory quotas
   for Lambda Functions and Lambda MicroVMs. AWS raises these quotas automatically based on your usage."
   One 4 GB MicroVM against a 400 GB (1,024 GB in us-east-1) regional default should be nothing, but
   `ServiceQuotaExceededException` on the very first `run-microvm` is a cheap thing to be surprised by
   once and an expensive thing to be surprised by inside a scheduled job.
6. **Whether `timeout` behaves across a suspend/resume boundary.** §5.3 makes this unreachable by
   configuration, which is the right answer, but if suspend is ever wanted the `TIMEOUT=30m` semantics
   need establishing first.

---

## 11. When to stay on EC2

Worth writing down so the decision does not have to be re-derived.

- **If the allowlist in `deploy/README.md` is a hard requirement**, MicroVMs costs a VPC egress connector,
  a NAT gateway and a domain-filtering firewall to get something an instance-level policy nearly gave for
  free. §5.4 argues that policy was aspirational, but that is an argument, not a fact about your
  obligations.
- **If a single issue starts taking more than about seven hours.** The backlog's largest items ("the LCOM
  family", "the six output formats") are called out as days of work, and the implementer is told to build
  the smallest coherent whole rather than a scaffold of stubs. If one invocation ever needs to span more
  than 8 hours of wall clock — not model time, wall clock, including the gate and three critics and three
  fix rounds — the ceiling becomes a real constraint again and the answer is the EC2 plan, or Fargate.
- **If you want the working tree to survive between sessions.** It does not here, by design, and §6 argues
  that is fine because the queue is GitHub and the history is the progress. If that ever stops being
  true — a long-lived branch, an experiment that spans nights — a persistent disk is worth more than a
  Firecracker boundary.

Otherwise: MicroVMs is the better host, and the reason is not the 8 hours. It is that the loop stops
paying when the queue empties, there is no instance anyone has to remember to stop, and
`--dangerously-skip-permissions` gets a hardware-virtualised boundary instead of a shared kernel.

# ArchUnitDev

An unattended implement / review / fix loop that works through a repository's open GitHub issues with
three Claude Code invocations: an **implementer**, a **correctness reviewer** and an **idiom critic**.

Built to drive [ArchUnitGo](https://github.com/LukasNiessen/ArchUnitGo) from an empty repo to a working
library across 44 dependency-ordered issues, but it is not specific to it beyond the prompts.

This repo is the harness only. The target repo is bind-mounted at `/work/repo`.

## The loop

```
for the lowest-numbered open issue:

    implementer  ──▶  ┌─ gate.sh ────────── build, vet, gofmt, test, architecture rules
                      │      │ fail
                      │      └──▶ fixer ──┐  (does not cost a review round)
                      │                   │
                      ├─ reviewer ────┐   │
                      │  idiom critic ┴───┴──▶ both PASS? ──▶ commit, push, close issue
                      │                            │ no
                      └────────── fixer ◀──────────┘   × MAX_ROUNDS
                                                       │ exhausted
                                    park on abandoned/issue-N, label needs-human, move on
```

**There is no state store.** The queue is "the lowest-numbered open issue", progress is the git history,
and the audit trail is the closed issues plus `NOTES.md` in the target repo. A killed run is resumed by
running the script again.

## Why it is shaped this way

**The deterministic gate runs before the reviewers.** `go build`, `go vet`, `gofmt`, `go test`, plus a
`grep` for the two architecture rules `AGENTS.md` says decay first. No model tokens are ever spent
reviewing code that does not compile, and a gate failure does not consume a review round.

**The critics cannot write.** They are restricted with `--tools "Read,Grep,Glob"`, so read-only is a
property of the invocation rather than a promise in a prompt. They never touch `git` either — the
harness generates the diff and pipes it in.

**Verdicts are validated JSON, not a sentinel string.** `--json-schema` forces `{verdict, findings[]}`
into the response's `structured_output` field, which the loop reads with `jq`. No `grep '^APPROVED'`
false positives.

**Everything fails closed.** A critic that crashes, times out or hits its budget cap counts as `FAIL`,
never as a silent pass.

**The two critics do not overlap.** The reviewer owns correctness, the data-model invariants and whether
the tests are real. The idiom critic owns conformance to `AGENTS.md` — the fluent-API grammar, the
naming table, the layout and the four dependency rules. Both are told to return `PASS` when their only
findings are cosmetic, which is what stops the idiom critic becoming a rename generator that never
approves.

**Reward hacking is checked for explicitly.** The cheapest way to make `go test` pass is to delete the
test, so `gate.sh` fails on `t.Skip`, commented-out test functions and a module with no tests, and both
critics are told to treat a weakened check as always blocking.

**Nothing is lost when an issue defeats the loop.** After `MAX_ROUNDS` the work is committed to
`abandoned/issue-N`, pushed, and the target repo is reset to the base commit so the next issue starts
from a clean tree.

## Auth

Inference goes through **Amazon Bedrock** (account `<aws-account-id>`, `us-east-1`). The image sets
`CLAUDE_CODE_USE_BEDROCK=1`, and `run.sh` verifies credentials with `aws sts get-caller-identity`
before the first issue rather than failing an hour into the night. No `ANTHROPIC_API_KEY` is involved.

**Use an EC2 instance profile.** Attach a role to the instance with `bedrock:InvokeModel` and
`bedrock:InvokeModelWithResponseStream`, and the SDK credential chain inside the container picks it up
from IMDS and refreshes it indefinitely. This is the only option that survives a full overnight run
without further work.

Two things to get right:

- **Do not set `AWS_PROFILE` in the container, and do not mount `~/.claude/settings.json`.** The host's
  `claude-code` profile resolves credentials with `credential_process = <credential-helper>`, and
  `<credential-helper>` does not exist in the image — so a container that inherits `AWS_PROFILE` fails to authenticate
  even though the instance profile would have worked. `run.sh` warns when it sees this combination.
- **Raise the IMDS hop limit to 2.** Docker's default bridge network adds a hop, and the EC2 default of
  `http-put-response-hop-limit = 1` therefore blocks containers from reaching IMDS at all:

  ```bash
  aws ec2 modify-instance-metadata-options \
    --instance-id i-xxxxxxxx --http-tokens required --http-put-response-hop-limit 2
  ```

  Or run the container with `--network host` and skip it.

For a smoke test from a laptop there is no IMDS to read, so pass short-lived credentials in. One issue
finishes well inside their lifetime, and `run.sh` warns that they will not refresh. Writing them to an
`--env-file` keeps them off the command line and out of your shell history:

```bash
$AWS_CREDS_CMD | tr ' ' '\n' > /tmp/aws.env
```

Egress needed: `bedrock-runtime.*.amazonaws.com` (the pinned model is a *global* inference profile, so
it may route across regions), `github.com` and `api.github.com` for `gh`, and
`proxy.golang.org` + `sum.golang.org` — the extractor depends on `golang.org/x/tools`, so `go build`
inside the gate will fetch modules. Notably **not** `api.anthropic.com`.

A `GH_TOKEN` with `repo` scope is required regardless — the loop reads, comments on and closes issues,
and pushes commits.

> This harness does **not** use `--bare`. That flag skips `CLAUDE.md` auto-discovery, and ArchUnitGo's
> `CLAUDE.md` is what points the agents at `AGENTS.md`. If you switch it on, pass the conventions in
> explicitly with `--add-dir` or `--append-system-prompt`.

## Running it

On EC2 in the Bedrock account, with an instance profile attached — nothing to pass but `GH_TOKEN`:

```bash
docker build -t archunitdev .

nohup docker run --rm \
  -e GH_TOKEN \
  -v "$PWD/ArchUnitGo:/work/repo" \
  -v "$PWD/logs:/work/logs" \
  archunitdev > loop.out 2>&1 &

tail -f logs/run.log
```

From a laptop, one issue, committing locally but pushing nothing:

```bash
$AWS_CREDS_CMD | tr ' ' '\n' > /tmp/aws.env

docker run --rm -it \
  --env-file /tmp/aws.env \
  -e GH_TOKEN="$(gh auth token)" \
  -e MAX_ISSUES=1 -e NO_PUSH=1 \
  -v "$HOME/Projects/ArchUnitGo:/work/repo" \
  -v "$PWD/logs:/work/logs" \
  archunitdev
```

Directly, without Docker — needs `claude`, `gh`, `jq`, `aws` and the Go toolchain on `PATH`. Your
`~/.claude/settings.json` already supplies the Bedrock wiring, so `MODEL=opus` works here:

```bash
REPO=/Users/rbz/Projects/ArchUnitGo LOGS=./logs MAX_ISSUES=1 MODEL=opus ./run.sh
```

`run.log` is the one-line-per-step narration. Everything else in `logs/` is per-invocation detail:
`N-implement.json` (the full envelope, including `total_cost_usd`), `N-review-1.verdict.json`,
`N-diff-1.patch`, `N-gate-1.txt`, and `*.debug.log`.

## Knobs

All environment variables, all with defaults that work:

| Variable | Default | |
|---|---|---|
| `REPO` | `/work/repo` | Target repository. |
| `LOGS` | `$HARNESS/logs` | Log directory. |
| `MAX_ROUNDS` | `3` | Review/fix rounds before an issue is abandoned. |
| `MAX_ISSUES` | `0` | `0` = run until the queue is empty. Set to `1` for a smoke test. |
| `PREFLIGHT_ONLY` | unset | Verify auth, tools, repo, remote and queue, then exit. Spends nothing. |
| `NO_PUSH` | unset | Commit locally, but do not push and do not close the issue. Use it for the first run. |
| `BUDGET_USD` | `5` | Per invocation, not per issue. |
| `TIMEOUT` | `30m` | Wall clock per invocation. |
| `MODEL` | `global.anthropic.claude-opus-5` | Bedrock model ID. The `opus` alias only resolves via `ANTHROPIC_DEFAULT_OPUS_MODEL`, which the container does not carry. |
| `FALLBACK_MODEL` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Used automatically when the primary is overloaded. |
| `MAX_DIFF_BYTES` | `400000` | Diff truncation point for the critics. |

Work up in two steps rather than trusting a fresh container with a night:

```bash
PREFLIGHT_ONLY=1 ./run.sh    # auth, tools, repo, remote, queue. Costs nothing.
MAX_ISSUES=1    ./run.sh     # issue #1 end to end. Costs a few dollars.
```

The second one is the one that tells you whether the prompts, the commit and the push path work.

## Cost

Roughly 3–7 invocations per issue (one implementer, two critics and one fixer per round). Budget on the
order of a few dollars per issue; `BUDGET_USD` caps each invocation and the run prints the total from the
JSON envelopes at the end. Watch the first two or three issues before walking away.

## Known limits

- **Sequential by design.** The issues are numbered in dependency order — #16 is meaningless without
  #1 — so parallel implementers would conflict and build against a kernel that does not exist yet.
- **Some issues are bigger than one sitting.** "Metrics: the LCOM family" and "Graph reports: the six
  output formats" are days of work. Expect a shallow first pass; the implementer is told to build the
  smallest coherent whole rather than a scaffold of stubs.
- **Large diffs are truncated** before the critics see them, and the truncation is logged as a warning
  rather than silently applied.
- **`--dangerously-skip-permissions` means what it says.** Claude can change anything in the mounted
  workspace and reach anything the container's network policy allows. Mount only the target repo, and
  put an egress policy on the container if the host has anything else worth reaching.

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

## Prerequisites

You need to pick an auth method, because the two behave differently in a container:

| | Env var | Notes |
|---|---|---|
| API key | `ANTHROPIC_API_KEY` | Simplest for unattended runs. Metered per token. |
| Subscription | `CLAUDE_CODE_OAUTH_TOKEN` | Generate with `claude setup-token` on a machine where you are logged in, then pass it as a secret. |

A `GH_TOKEN` with `repo` scope is also required — the loop reads, comments on and closes issues, and
pushes commits.

> Note: this harness does **not** use `--bare`. That flag skips `CLAUDE.md` auto-discovery, and
> ArchUnitGo's `CLAUDE.md` is what points the agents at `AGENTS.md`. If you switch it on, pass the
> conventions in explicitly with `--add-dir` or `--append-system-prompt`.

## Running it

```bash
docker build -t archunitdev .

docker run --rm -it \
  -e ANTHROPIC_API_KEY \
  -e GH_TOKEN \
  -v /home/ec2-user/ArchUnitGo:/work/repo \
  -v /home/ec2-user/logs:/work/logs \
  archunitdev
```

Directly, without Docker — needs `claude`, `gh`, `jq` and the Go toolchain on `PATH`:

```bash
REPO=/Users/you/Projects/ArchUnitGo LOGS=./logs ./run.sh
```

### On EC2

```bash
nohup docker run --rm \
  -e ANTHROPIC_API_KEY -e GH_TOKEN \
  -v "$PWD/ArchUnitGo:/work/repo" -v "$PWD/logs:/work/logs" \
  archunitdev > loop.out 2>&1 &

tail -f logs/run.log
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
| `BUDGET_USD` | `5` | Per invocation, not per issue. |
| `TIMEOUT` | `30m` | Wall clock per invocation. |
| `MODEL` | `opus` | |
| `FALLBACK_MODEL` | `sonnet` | Used automatically when the primary is overloaded. |
| `MAX_DIFF_BYTES` | `400000` | Diff truncation point for the critics. |

**Do a single-issue dry run first.** `MAX_ISSUES=1 ./run.sh` costs a few dollars and tells you whether
the prompts, auth and push path all work, which is worth knowing before committing to a night.

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

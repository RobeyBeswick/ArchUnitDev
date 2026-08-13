# ArchUnitDev

An unattended implement / review / fix loop that works through a repository's open GitHub issues with
three Claude Code invocations: an **implementer**, a **correctness reviewer** and an **idiom critic**.

Built to drive [ArchUnitGo](https://github.com/LukasNiessen/ArchUnitGo) from an empty repo to a working
library across 44 dependency-ordered issues, but it is not specific to it beyond the prompts.

This repo is the harness only. The target repo is bind-mounted at `/work/repo`.

## The loop

```
for the lowest-numbered open issue:

    implementer  ──▶  ┌─ gate.sh ────────── build, vet, golangci-lint, test -race, cross-compile
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

**The deterministic gate runs before the reviewers.** `go build`, `go vet ./...`, `golangci-lint`,
`go test -race -shuffle=on -covermode=atomic`, `go mod tidy -diff`, and a cross-compile for
`windows/amd64` and `linux/386`. No model tokens are ever spent reviewing code that does not compile,
and a gate failure does not consume a review round.

**The architecture rules live in the target repo's `.golangci.yml`, not in `gate.sh`.** They used to be
`grep`s over import lines. They are now `depguard` rules over the *resolved* import graph, so an
aliased, blank or line-wrapped import cannot slip past them — and the implementer can run exactly the
check the gate will run, before it finishes. `AGENTS.md`'s dependency rules 1–3, the purity rule for
`assertion`/`projection`/`calculation`, "globs compile to regex in one place" and the doc-comment rules
are all expressed there. Rule 4 (*nothing imports the root package*) is the one `depguard` structurally
cannot express, because it matches path prefixes and the public surface's path is the module path
itself, so the idiom critic owns that one by hand.

Two consequences, both handled in preflight rather than discovered in the morning: a missing
`golangci-lint` binary and a missing `.golangci.yml` are **fatal**, not warnings. Either one makes the
gate go green while checking a fraction of what it claims to — golangci-lint with no config silently
falls back to five default linters. `ALLOW_NO_LINT=1` overrides both and drops back to the grep
fallbacks, with a loud banner in the gate log.

**Moving those checks out of the prompts is what makes the critics useful.** Both critic prompts open
with an explicit list of what the toolchain has already proven, and an instruction not to report any of
it. A critic spending its round on a missing doc comment is a round not spent on the things no linter
can see: a fixture that cannot physically produce the violation it claims to test, a doc comment that is
well-formed but false, or a value-receiver builder doing `append(b.xs, x)` without a clone — which
compiles, passes every linter, passes single-branch tests, and silently corrupts one branch of a
half-built rule whenever `cap > len`.

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

**Reward hacking is checked for explicitly.** The cheapest way to make `go test` pass is to stop running
the tests, so `gate.sh` fails on `t.Skip` (unless the line carries an `ALLOW-SKIP: <reason>`, so a
genuinely platform-specific skip cannot deadlock the loop), on a commented-out test function, on a
module with no tests, and on **a test-function count lower than at the base commit** — which is the one
thing coverage cannot tell you, because a deleted test takes its uncovered lines with it. `errcheck`
with `check-blank` covers `_ =`, and `go vet`/`SA4011` cover `if false`. Both critics are told to treat a
weakened check as always blocking, and the fixer is told that weakening `.golangci.yml` counts as
weakening the checks.

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
inside the gate will fetch modules. The image build additionally needs
`raw.githubusercontent.com` and `objects.githubusercontent.com` for the `golangci-lint` installer,
though not at run time. Notably **not** `api.anthropic.com`.

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

Directly, without Docker — needs `claude`, `gh`, `jq`, `aws`, the Go toolchain and
`golangci-lint` (>= v2.5.0, `brew install golangci-lint`) on `PATH`. Your
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
| `TIMEOUT` | `30m` | Wall clock per invocation. |
| `MODEL` | `global.anthropic.claude-opus-5` | Bedrock model ID. The `opus` alias only resolves via `ANTHROPIC_DEFAULT_OPUS_MODEL`, which the container does not carry. |
| `FALLBACK_MODEL` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Used automatically when the primary is overloaded. |
| `MAX_DIFF_BYTES` | `400000` | Diff truncation point for the critics. |
| `LINT` | `golangci-lint` | The linter binary. Only worth setting to test the fallback path. |
| `ALLOW_NO_LINT` | unset | Run a Go repo without `golangci-lint` or without a `.golangci.yml`. Downgrades the architecture rules to greps. Do not use for an unattended run. |
| `ALLOW_STATIC_CREDS` | unset | Permit an unbounded run on static temporary credentials, which will expire partway through the night. |

Work up in three steps rather than trusting a fresh container with a night:

```bash
./test/loop_test.sh          # the harness itself, with stubbed claude and gh. Costs nothing.
PREFLIGHT_ONLY=1 ./run.sh    # auth, tools, repo, remote, queue. Costs nothing.
MAX_ISSUES=1    ./run.sh     # issue #1 end to end. Costs a few dollars.
```

The last one is the one that tells you whether the prompts, the commit and the push path work.

## Testing the harness

`test/loop_test.sh` runs `run.sh` end to end against a throwaway git repo with `claude` and `gh` stubbed
out on `PATH`. No model, no network, no spend, a couple of seconds.

It exists because the paths that matter most are the ones a real run almost never takes. Issue #1 went
through with both critics passing on the first round, which validated exactly none of the review
machinery. The scenarios are:

| Scenario | What it pins down |
|---|---|
| `happy` | Both critics pass: commit, push, close, and no coverage profile left in the repo. |
| `fixround` | A critic returns `FAIL`; the finding's `problem` and `fix` text reach the fix prompt; round 2 re-reviews and lands. |
| `garbage` | A critic returns unparseable output: fail closed, with a synthesised finding, never a silent pass. |
| `abandon` | `MAX_ROUNDS` exhausted: work parked on `abandoned/issue-N`, pushed, repo reset to base, issue labelled and skipped, run carries on. |
| `no_push` | `NO_PUSH=1` commits locally and touches nothing remote. |
| `preflight` | A Go repo with no `.golangci.yml`, and a missing linter binary, are both fatal — and `ALLOW_NO_LINT=1` overrides both. |

```bash
./test/loop_test.sh                 # all of them
./test/loop_test.sh fixround        # one
KEEP=1 ./test/loop_test.sh abandon  # leave the temp repo behind to poke at
```

The stubs are in `test/stub/`. `claude` works out which invocation it is from the `--debug-file` path —
the only place `run.sh` puts the tag on the command line — captures its stdin so the test can assert on
what the harness actually put in each prompt, and edits the working tree so the diff is non-empty.
`timeout` is a shim: it is coreutils, present in the image but not on a stock macOS box.

## Cost

Roughly 3–7 invocations per issue (one implementer, two critics and one fixer per round). Budget on the
order of a few dollars per issue, and the run prints the total from the JSON envelopes at the end.

**There is deliberately no per-invocation spend cap.** There was one (`--max-budget-usd`) and it was
removed: an invocation that hits a cap is killed mid-edit, which for the implementer means a half-written
package that the gate then rejects, and for a critic means no verdict at all — the fail-closed path turns
that into a `FAIL` and burns a round on a finding nobody wrote. A truncated round costs more than the
tokens it saved. `TIMEOUT` is the remaining stop, and a wall clock is the honest one: it bounds a *wedged*
invocation without punishing an expensive but productive one. Watch the first two or three issues before
walking away.

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

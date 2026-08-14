# ArchUnitDev

An unattended implement / review / fix loop that works through a repository's open GitHub issues with
four Claude Code invocations: an **implementer**, a **correctness reviewer**, an **idiom critic** and a
**test critic**.

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
                      ├─ idiom critic │   │
                      │  test critic  ┴───┴──▶ all PASS? ───▶ commit, push, close issue
                      │                            │ no
                      └────────── fixer ◀──────────┘   × MAX_ROUNDS
                                                       │ exhausted
                                    park on abandoned/issue-N, label needs-human, move on

once the batch is done, if RETRO=1:

    retro.sh ──▶ reads every artifact the batch left ──▶ a report proposing changes to the harness
                 (read-only: it judges the prompts, it does not edit them)
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

**Preflight's job is the failures that do not announce themselves.** A blocked module proxy is the
clearest example, because of *how* it fails: `go get` on an unreachable proxy does not error, it hangs
past 30 seconds with no output, so the implementer spends its wall clock waiting, gets killed by
`TIMEOUT`, and hands back an unfinished issue with nothing in the log pointing at DNS — and then does
it again for every issue after that. One 15-second read-only `go list -m` at startup turns that into a
line naming the cause and the fix. It warns rather than dying, because most issues add no dependency
and killing a night's run over a proxy nothing in the queue needs would cost more than it saves.

Two more consequences, both handled in preflight rather than discovered in the morning: a missing
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

**Everything fails closed.** A critic that crashes or times out counts as `FAIL`, never as a silent pass.
Approval is unanimous, and the critics run concurrently, so a third reviewer costs about a dollar a round
and no wall-clock at all.

**The three critics do not overlap**, and keeping them disjoint is the whole design. The reviewer owns
correctness and the data-model invariants. The idiom critic owns conformance to `AGENTS.md` — the
fluent-API grammar, the naming table, the layout and the four dependency rules. The test critic owns
whether the tests would fail if the code were wrong. All three are told to return `PASS` when their only
findings are cosmetic, which is what stops the idiom critic becoming a rename generator that never
approves. Each round, only the critics that actually found something contribute a section to the fixer's
prompt.

**The test critic exists because the other two demonstrably missed this class of defect.** On issue #2
both returned `PASS` with no findings, and the diff contained a `TestFiltersAreImmutable` that passed
against a `Filter.Excluding` with its `slices.Clone` deleted — it asserted only that the *parent* was
unchanged, which is true even with the bug, because appending to a nil slice always allocates. Run
against that same diff afterwards, the test critic found it, plus a second gap nobody had noticed: the
separator normalisation in `Filter.Matches` could be deleted with the whole suite still green, because
`Pattern.Matches` normalises a second time and no Filter-level test ever passed a backslash. Both were
confirmed by mutating the code and re-running.

It has since done the same thing inside the loop, on its first live run. On issue #5 the implementer's
`WithDefaults` returned a bare `*o`, which copies the struct but leaves `BuildTags` pointing at the
caller's backing array — a terminal appending a build tag to its resolved options would write through
into the user's own. The correctness reviewer and the idiom critic passed it in every round. The test
critic blocked on the test instead of the code: the aliasing test only asserted that the caller was
unchanged, and the one field where copying is a real decision was never touched. The fixer's response
was to add the `slices.Clone`. Three instances of that bug class so far, and this reviewer has caught
all three.

The same issue is the argument for its round-2 finding too, and against how it delivered it: the second
verdict said the test never asserted that the resolved copy *carries* the caller's values, so
`WithDefaults` dropping four of six fields was undetectable — which was equally true of the round-1
test. Two findings about one test, one round apart, on an issue that then landed on the last round it
had. All three prompts now say to report everything blocking in one pass, because a held-back finding
is a round the issue may not have.

Its prompt is built on one mechanism — **name the mutation**. For every test, state the one-line change
to the implementation that makes it fail; if you cannot, the test asserts nothing and that is a block.
It is explicitly forbidden from reporting coverage percentages (there is no threshold in the gate) or
asking for a test without naming what would break, which is how a test reviewer turns into a
work generator.

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
it may route across regions), `github.com` and `api.github.com` for `gh`, and somewhere to resolve Go
modules from — the extractor depends on `golang.org/x/tools`, so `go build` inside the gate needs it.
Which host that is depends on `GOPROXY`:

| `GOPROXY` | Needs |
|---|---|
| default | `proxy.golang.org` + `sum.golang.org` |
| `direct` | the VCS host of every dependency — `go.googlesource.com` for `x/tools` — plus `sum.golang.org` |

The default is the narrower and faster of the two, which is why the image does not change it. Use
`direct` (`-e GOPROXY=direct`) only where `proxy.golang.org` is blocked, and note that its egress set
is open-ended: it is wherever the dependencies happen to be hosted, so it cannot be pinned in a policy
the way one proxy hostname can.

The image build warms the module cache for `golang.org/x/tools`, so the first gate run does not spend
the implementer's wall clock fetching it. That reduces the module traffic but **does not remove the
need for it**, and the reason is worth knowing before you write an egress policy that assumes
otherwise: what a warm cache cannot answer is *version resolution*. Adding a new import and running
`go get golang.org/x/tools@latest` or `go mod tidy` asks "which version is latest", which is a network
lookup with no cache fallback — verified: it fails under `GOPROXY=off` against a fully populated cache.
Only once the version is pinned in `go.mod` is the whole build satisfiable offline, and then it needs
a `go mod tidy` too, because `go get module@version` records no checksums for the module's own
dependencies. So `go build` on a settled `go.mod` is offline-capable; the commit that first adds the
dependency is not.

The image build additionally needs `raw.githubusercontent.com` and `objects.githubusercontent.com` for
the `golangci-lint` installer, plus whatever `GOPROXY` resolves to for the cache warm — pass
`--build-arg GOPROXY=direct` if the build host is the blocked one. Neither is needed at run time.
Notably **not** `api.anthropic.com`.

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

Two of the files in `logs/` are state rather than output, and they are the only state the harness
keeps outside git and the issues themselves. `skipped` lists the issues abandoned after
`MAX_ROUNDS`; `landed` lists the issues that were implemented but deliberately left open, which
only happens under `NO_PUSH`. Both are excluded from the queue. Delete them to make the loop
reconsider an issue — and delete `landed` if you throw away the local commits it refers to,
or the queue will skip work that is no longer there.

`landed` is pruned at startup of any entry whose issue is no longer open, and that is not tidiness.
Reopening an issue is how a human says the work was not good enough; a permanent skip entry would make
that reopened issue invisible to the queue for ever, with the run cheerfully reporting an empty backlog.
An entry for an issue that is still open is left alone, which is the case the file exists for.

## The retrospective

The critics judge each diff. Nothing judged the *loop* — whether a round was wasted, whether a critic
that fails everything is pointing at a missing lint rule, whether three passes let something through
— and that has so far been a human reading `logs/` by hand. `retro.sh` is that pass:

```bash
RETRO=1 MAX_ISSUES=3 ./run.sh     # at the end of the batch
./retro.sh 11 12 13               # or afterwards, on any batch already in logs/
./retro.sh                        # every issue this log directory holds artifacts for
PACK_ONLY=1 ./retro.sh            # the evidence, without spending anything on the model
```

It is worth understanding what it is and is not:

* **It reviews the machinery, not the code.** Its subject is `prompts/*.md`, `gate.sh` and the round
  structure. The code already had three critics and a gate.
* **It is cross-issue, which is where the signal is.** "The idiom critic blocked all three issues over
  the same convention" is an argument for a lint rule in the target repo, paid for once, instead of a
  judgement bought again on every issue. One issue cannot tell you that.
* **The numbers are computed, not summarised.** Rounds, verdicts, finding counts, gate outcomes and
  costs come out of the artifacts in bash before the model sees anything, so the report can be checked
  against the same files. `PACK_ONLY=1` prints exactly what it was given.
* **It is read-only by tool restriction**, like the critics — `Read,Grep,Glob`. A pass that edits the
  prompts it is judging is one nobody can audit, and it would be rewriting files a running loop has
  open. It proposes; you decide.
* **It cannot fail the run.** It goes last, after the spend line, and its exit status is discarded. The
  batch has already landed by then, and a retrospective that crashes must not turn a good night into a
  failed one.
* **"No change needed" is a valid report**, and the prompt says so explicitly. Otherwise it invents
  work to justify itself, which is worse than not running it.

One batch of three is an observation, not a trend — the prompt is told to say "observed once" rather
than dress a single instance up as a pattern. It gets more useful the more issues it has to look across.

## Knobs

All environment variables, all with defaults that work:

| Variable | Default | |
|---|---|---|
| `REPO` | `/work/repo` | Target repository. |
| `LOGS` | `$HARNESS/logs` | Log directory. |
| `MAX_ROUNDS` | `3` | Review/fix rounds before an issue is abandoned. |
| `MAX_ISSUES` | `0` | Issues to *attempt*, abandonments included — a bound on what the run touches and what it spends, not on how much of it lands. `0` = run until the queue is empty. Set to `1` for a smoke test. |
| `MAX_CONSECUTIVE_ABANDONS` | `2` | Stop the run after this many issues are abandoned back to back, on the reasoning that a run of abandons is far more often a broken environment than several independently hard issues. `0` = never stop. |
| `PREFLIGHT_ONLY` | unset | Verify auth, tools, repo, remote and queue, then exit. Spends nothing. |
| `NO_PUSH` | unset | Commit locally, but do not push and do not close the issue. Use it for the first run. The issue is recorded in `logs/landed` so the queue still advances. |
| `TIMEOUT` | `30m` | Wall clock per invocation. |
| `MODEL` | `global.anthropic.claude-opus-5` | Bedrock model ID. The `opus` alias only resolves via `ANTHROPIC_DEFAULT_OPUS_MODEL`, which the container does not carry. |
| `FALLBACK_MODEL` | `us.anthropic.claude-sonnet-4-5-20250929-v1:0` | Used automatically when the primary is overloaded. |
| `MAX_DIFF_BYTES` | `400000` | Diff truncation point for the critics. |
| `LINT` | `golangci-lint` | The linter binary. Only worth setting to test the fallback path. |
| `ALLOW_NO_LINT` | unset | Run a Go repo without `golangci-lint` or without a `.golangci.yml`. Downgrades the architecture rules to greps. Do not use for an unattended run. |
| `ALLOW_DIRTY` | unset | Start even though the target repo has uncommitted changes, accepting that the first issue's commit will contain them. |
| `ALLOW_STATIC_CREDS` | unset | Permit an unbounded run on static temporary credentials, which will expire partway through the night. |
| `RETRO` | unset | Run `retro.sh` on the batch when the run finishes: a report on the harness itself, not on the code. Costs one extra invocation and is only worth it once several issues have been through. |
| `PACK_ONLY` | unset | `retro.sh` only. Print the evidence pack and exit without calling the model. |
| `SKIP_MODULE_CHECK` | unset | Skip the preflight module-resolution probe. Worth setting only for an air-gapped run against a settled `go.mod`, where the warning is accurate but not actionable. |

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
| `happy` | All three critics pass: commit, push, close, and no coverage profile left in the repo. |
| `fixround` | A critic returns `FAIL`; the finding's `problem` and `fix` text reach the fix prompt; round 2 re-reviews and lands. |
| `testcritic` | Only the third critic objects: its findings reach the fixer attributed to it, and the two that passed contribute no empty section. |
| `garbage` | A critic returns unparseable output: fail closed, with a synthesised finding, never a silent pass. |
| `abandon` | `MAX_ROUNDS` exhausted: work parked on `abandoned/issue-N`, pushed, repo reset to base, issue labelled and skipped, run carries on. |
| `nodiff` | The implementer changes nothing: no critic and no fixer run, no commit, no empty branch, the issue is skipped and flagged, and the abandon line says *that* rather than blaming three rounds of review. |
| `no_push` | `NO_PUSH=1` commits locally and touches nothing remote. |
| `two_issues` | Two issues in one run: the queue advances, the second issue's base is the first one's commit, and each issue is implemented exactly once. |
| `pushfail` | A failed push stops the run and leaves the issue open: the work is committed locally, so nothing is lost, but nothing is reported done. |
| `breaker` | Consecutive abandonments stop the run before the rest of the queue is spent on a broken environment — and `MAX_CONSECUTIVE_ABANDONS=0` runs it out anyway. |
| `preflight` | A Go repo with no `.golangci.yml`, and a missing linter binary, are both fatal — and `ALLOW_NO_LINT=1` overrides both. |
| `moduleproxy` | An unresolvable module proxy warns and carries on rather than killing the run, names `GOPROXY=direct` as the fix, and the probe stays read-only. |
| `bounded` | `MAX_ISSUES` counts attempts, not landings: a queue whose first issue abandons stops at the bound instead of reaching for another issue to make the numbers up, and a landing counts the same as an abandonment. |
| `retro_pack` | The evidence pack is arithmetic over hand-written artifacts: issues sorted numerically rather than lexically (`2` before `11`), landed-but-open told apart from abandoned, per-round gate outcomes and per-critic verdicts, cost summed per issue, and rounds that never ran not invented. |
| `retro` | `RETRO=1` reviews the batch that just landed and not an earlier batch's artifacts in the same log directory, writes its report to `logs/` and to stdout, and cannot fail the run. Also the one place the suite asserts that `GH_TOKEN` reaches no model invocation at all — the harness's only enforced boundary. |
| `dirty` | Uncommitted changes in the target repo are fatal before any model is invoked, the files are named, and `ALLOW_DIRTY=1` runs anyway and commits them as warned. |
| `relative_logs` | A relative `LOGS` — the invocation this README documents — still logs to the right place after the script cds into the target repo, and writes nothing into that repo. |

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

Roughly 4–9 invocations per issue (one implementer, three critics and one fixer per round). Budget on the
order of a few dollars per issue, and the run prints the total from the JSON envelopes at the end.
`RETRO=1` adds one invocation per *batch*, not per issue, and reads artifacts rather than the repository.

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

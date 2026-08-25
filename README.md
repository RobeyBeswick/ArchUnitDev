# ArchUnitDev

An unattended implement / review / fix loop that works through a repository's open GitHub issues with
four opencode invocations: an **implementer**, a **correctness reviewer**, an **idiom critic** and a
**test critic**. It was built to drive [ArchUnitGo](https://github.com/LukasNiessen/ArchUnitGo) from an
empty repo to a working library across 44 dependency-ordered issues, but it is not specific to it beyond
the prompts. This repo is the harness only; the target repo is bind-mounted at `/work/repo`.

## Contents

- [What it is](#what-it-is)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
  - [The loop](#the-loop)
  - [State](#state)
  - [The gate](#the-gate)
  - [Roles](#roles)
  - [Preflight](#preflight)
  - [Abandonment and retry](#abandonment-and-retry)
  - [Spend cap](#spend-cap)
  - [Retrospective](#retrospective)
- [Configuration](#configuration)
  - [Knobs](#knobs)
  - [Authentication](#authentication)
  - [Network egress](#network-egress)
- [Testing](#testing)
- [Cost](#cost)
- [Limitations](#limitations)
- [Design notes](#design-notes)

## What it is

- One run processes the queue of open GitHub issues in dependency order. Each issue goes through
  implement → gate → review → fix rounds, and is committed, pushed and closed on unanimous approval.
- Four agent roles per round: an implementer, a correctness reviewer, an idiom critic and a test critic.
- It runs unattended overnight and is resumable — there is no state store, just git history.
- It is the harness only. The target repo is bind-mounted at `/work/repo`.

## Quick start

Work up in three steps rather than trusting a fresh container with a night:

```bash
./test/loop_test.sh          # the harness itself, with stubbed opencode and gh. Costs nothing.
PREFLIGHT_ONLY=1 ./run.sh    # auth, tools, repo, remote, queue. Costs nothing.
MAX_ISSUES=1    ./run.sh     # issue #1 end to end. Costs a few dollars.
```

The last one is the one that tells you whether the prompts, the commit and the push path work.

### On EC2

With opencode authenticated (`opencode auth login` inside the image, or a provider `*_API_KEY` env var),
nothing else to pass but `GH_TOKEN`:

```bash
docker build -t archunitdev .

nohup docker run --rm \
  -e GH_TOKEN \
  -e MODEL=opencode-go/deepseek-v4-pro \
  -e FLASH_MODEL=opencode-go/deepseek-v4-flash \
  -v "$PWD/ArchUnitGo:/work/repo" \
  -v "$PWD/logs:/work/logs" \
  archunitdev > loop.out 2>&1 &

tail -f logs/run.log
```

### From a laptop (one issue, commit locally, push nothing)

```bash
docker run --rm -it \
  -e GH_TOKEN="$(gh auth token)" \
  -e MAX_ISSUES=1 -e NO_PUSH=1 \
  -v "$HOME/.local/share/opencode:/home/dev/.local/share/opencode" \
  -v "$HOME/Projects/ArchUnitGo:/work/repo" \
  -v "$PWD/logs:/work/logs" \
  archunitdev
```

Mounting `~/.local/share/opencode` carries your logged-in provider auth into the container. `aws` is no
longer needed on `PATH` for inference — only for the optional EC2 plumbing in `deploy/`.

### Directly (no Docker)

Needs `opencode`, `gh`, `jq`, the Go toolchain and `golangci-lint` (>= v2.5.0,
`brew install golangci-lint`) on `PATH`. opencode carries its own provider auth (`opencode auth login`
or a `*_API_KEY` env var), so `MODEL=opencode-go/deepseek-v4-pro` works here:

```bash
REPO=/Users/rbz/Projects/ArchUnitGo LOGS=./logs MAX_ISSUES=1 ./run.sh
```

### Logs

`run.log` is the one-line-per-step narration. Everything else in `logs/` is per-invocation detail:
`N-implement.json` (the full envelope, including `total_cost_usd`), `N-review-1.verdict.json`,
`N-diff-1.patch`, `N-gate-1.txt`, and `*.debug.log`.

Two of the files in `logs/` are state rather than output — the only state the harness keeps outside git
and the issues themselves:

- `skipped` — issues abandoned after `MAX_ROUNDS`; an issue is taken back off it if a re-attempt lands.
  The queue and the retrospective both read it.
- `landed` — issues implemented but deliberately left open, which only happens under `NO_PUSH`. Pruned at
  startup of any entry whose issue has closed, so reopening an issue keeps it visible to the queue.

Both are excluded from the queue. Delete them to make the loop reconsider an issue.

## How it works

### The loop

```text
for the lowest-numbered open issue:

    implementer  ──▶  ┌─ gate.sh ────────── build, vet, golangci-lint, test -race, cross-compile
                      │      │ fail
                      │      └──▶ fixer ──┐  (does not cost a review round)
                      │                   │
                      ├─ reviewer ────┐   │
                      ├─ idiom critic │   │
                      │  test critic ×2───┴──▶ all PASS? ───▶ commit, push, close issue
                      │                            │ no
                      └────────── fixer ◀──────────┘   × MAX_ROUNDS, then judge
                                                       │ once more and stop
                                    park on abandoned/issue-N, label needs-human, move on
                                                       │
                                    and once the queue is done, one more attempt at it
                                    on the tree the batch finished with

once the batch is done, if RETRO=1:

    retro.sh ──▶ reads every artifact the batch left ──▶ a report proposing changes to the harness
                 (read-only: it judges the prompts, it does not edit them)
```

`×2`: the roles in `DOUBLE_CRITICS` run twice in round 1, differently prompted, findings unioned.

### State

There is no state store. The queue is "the lowest-numbered open issue", progress is the git history, and
the audit trail is the closed issues plus `NOTES.md` in the target repo. A killed run is resumed by
running the script again.

### The gate

`gate.sh` dispatches to the deterministic checks for the target repo's stack, `gate/$TARGET_LANG.sh`,
which runs before any reviewer sees the diff. For Go that is `go build`, `go vet ./...`,
`golangci-lint`, `go test -race -shuffle=on -covermode=atomic`, `go mod tidy -diff`, and a cross-compile
for `windows/amd64` and `linux/386`. For C# it is `dotnet restore`, `dotnet build --no-restore`,
`dotnet format --verify-no-changes`, `dotnet test --no-build`, a `win-x64` cross-RID publish and the
vulnerability scan. A gate failure goes to the fixer and does not consume a review round. A language is
added by writing its gate script and its prompts; the loop does not know which one it is driving.

### Roles

Each round invokes the four agents concurrently:

- **implementer** — writes the diff.
- **correctness reviewer** — owns correctness and the data-model invariants.
- **idiom critic** — owns conformance to `AGENTS.md`: the fluent-API grammar, the naming table, the
  layout and the four dependency rules.
- **test critic** — owns whether the tests would fail if the code were wrong.

The critics are read-only by agent permission (the `readonly` agent denies write/bash) and never touch
`git`; the harness generates the diff and pipes it in. Verdicts are JSON (`{verdict, findings[]}`)
validated with `jq` from the critic's text, so there are no `grep '^APPROVED'` false positives — a
critic that did not answer in JSON fails closed exactly like one that crashed. Approval is unanimous.

### Preflight

Before the first issue, preflight verifies auth, tools, repo, remote and queue. Its job is the failures
that do not announce themselves:

- **Blocked module proxy** (warning). `go get` on an unreachable proxy hangs past 30 seconds with no
  output, so the implementer gets killed by `TIMEOUT` with nothing in the log pointing at DNS — and then
  does it again for every issue. One 15-second read-only `go list -m` at startup turns that into a line
  naming the cause and the fix. It warns rather than dying, because most issues add no dependency.
- **Missing `golangci-lint` binary** (fatal). The gate would go green while checking a fraction of what
  it claims.
- **Missing `.golangci.yml`** (fatal). `golangci-lint` with no config silently falls back to its five
  default linters.

`ALLOW_NO_LINT=1` overrides both fatal checks and drops back to the grep fallbacks, with a loud banner in
the gate log.

### Abandonment and retry

- **Abandon.** After `MAX_ROUNDS` fixes and one final judged round, the work is committed to
  `abandoned/issue-N`, pushed, and the target repo reset to the base commit. The commit message carries
  the reason and the verdicts its tip was judged on — the handoff to whoever picks the issue up.
- **Retry.** The backlog is numbered in dependency order, so an abandonment leaves a hole in the middle
  of an ordered queue. When the queue is done, every issue this run abandoned is re-attempted once on the
  tree the batch actually reached — a fresh implementer on a bigger base, not a fourth fix round on a
  diff that had stopped converging.

The retry is fenced three ways:

- Only issues **this run** abandoned — an entry already in `skipped` is a human's call.
- Only when **the base moved** — otherwise the same prompts over the same tree fail the same way.
- Only **once** — a re-attempt that fails again parks on `abandoned/issue-N-attempt-2`.

The re-attempt is handed the findings still outstanding when the first attempt was abandoned, under a
heading that says what they are. It is exempt from `MAX_ISSUES` (a re-attempt of #21 is still #21) and
does not run after `MAX_CONSECUTIVE_ABANDONS` trips (a broken environment is the one case where spending
again is certainly wrong). Set `RETRY_ABANDONED=` to switch it off.

### Spend cap

`MAX_SPEND` bounds the run in dollars, not issues — `MAX_ISSUES` bounds a count, and issues do not cost
the same. The cap stops the run at the first issue boundary where this run's spend has reached it, and
every boundary narrates the running total whether or not a cap is set.

It is checked *between* issues and deliberately nowhere else: an issue killed part-way through has an
unjudged diff and no branch, which is the outcome the abandon path exists to prevent. Spend is summed
from the `total_cost_usd` in each invocation's result JSON, counting only files newer than a marker
touched at startup (`logs/` is long-lived and holds every batch). The end-of-run line reports this run's
spend and the directory's lifetime spend as two separate numbers.

### Retrospective

The critics judge each diff. `retro.sh` judges the *loop* itself — whether a round was wasted, whether a
critic that fails everything is pointing at a missing lint rule, whether three passes let something
through.

```bash
RETRO=1 MAX_ISSUES=3 ./run.sh     # at the end of the batch
./retro.sh 11 12 13               # or afterwards, on any batch already in logs/
./retro.sh                        # every issue this log directory holds artifacts for
PACK_ONLY=1 ./retro.sh            # the evidence, without spending anything on the model
```

- It reviews the machinery, not the code — its subject is `prompts/$TARGET_LANG/*.md`, `gate.sh` and the round
  structure.
- It is cross-issue, which is where the signal is. One issue cannot tell you that the same convention
  blocked three.
- The numbers are computed, not summarised — rounds, verdicts, finding counts, gate outcomes and costs
  come out of the artifacts in bash before the model sees anything. `PACK_ONLY=1` prints exactly what it
  was given.
- It is read-only by tool restriction (`Read,Grep,Glob`). It proposes; you decide.
- It cannot fail the run — it goes last, after the spend line, and its exit status is discarded.
- "No change needed" is a valid report, and the prompt says so explicitly. One batch of three is an
  observation, not a trend.

## Configuration

### Knobs

All environment variables, all with defaults that work:

| Variable | Default | Description |
|---|---|---|
| `REPO` | `/work/repo` | Target repository. |
| `LOGS` | `$HARNESS/logs` | Log directory. |
| `TARGET_LANG` | `go` | The language stack of the target repo. Selects the deterministic gate (`gate/$TARGET_LANG.sh`) and the prompt set (`prompts/$TARGET_LANG/`). A language is added by writing its gate script and its prompts; the loop itself is language-agnostic. Deliberately not named `LANG`, which is the POSIX locale variable. |
| `MAX_ROUNDS` | `3` | *Fix* rounds before an issue is [abandoned](#abandonment-and-retry). The loop runs one more judged round than this, so its last act on an issue is always a gate plus a verdict, never a fix nobody looked at. `MAX_ROUNDS=3` means at most 3 fixes and up to 4 rounds of critics. |
| `MAX_ISSUES` | `0` | Issues to *attempt*, abandonments included — a bound on what the run touches and what it spends, not on how much of it lands. `0` = run until the queue is empty. Set to `1` for a [smoke test](#quick-start). |
| `MAX_CONSECUTIVE_ABANDONS` | `2` | Stop the run after this many issues are abandoned back to back, on the reasoning that a run of abandons is far more often a broken environment than several independently hard issues. `0` = never stop. |
| `RETRY_ABANDONED` | `1` | Re-attempt each issue this run abandoned, once, after the queue is done — but only if something landed after it. Exempt from `MAX_ISSUES`; skipped entirely if the abandon breaker tripped. Empty = off. See [abandonment and retry](#abandonment-and-retry). |
| `DOUBLE_CRITICS` | `tests` | Roles that run **twice** in round 1, concurrently, with their findings unioned — the second pass told to sweep exhaustively rather than report what matters most. Empty = every role runs once. See [design notes](#design-notes). |
| `MAX_SPEND` | `0` | Dollars *this run* may spend before it stops. Checked at issue boundaries only; measured from each invocation's `total_cost_usd`, counting only this run's artifacts. `0` = no cap. See [spend cap](#spend-cap). |
| `PREFLIGHT_ONLY` | unset | Verify auth, tools, repo, remote and queue, then exit. Spends nothing. See [preflight](#preflight). |
| `NO_PUSH` | unset | Commit locally, but do not push and do not close the issue. Use it for the first run. The issue is recorded in `logs/landed` so the queue still advances. |
| `TIMEOUT` | `30m` | Wall clock per invocation. |
| `MODEL` | `opencode-go/deepseek-v4-pro` | opencode `provider/model` ID for the reasoning roles — the implementer and the three critics. |
| `FLASH_MODEL` | `opencode-go/deepseek-v4-flash` | opencode `provider/model` ID for the cheap roles — the fixer and the retrospective. |
| `MAX_DIFF_BYTES` | `400000` | Diff truncation point for the critics. |
| `LINT` | `golangci-lint` | The linter binary. Only worth setting to test the fallback path. |
| `ALLOW_NO_LINT` | unset | Run a Go repo without `golangci-lint` or without a `.golangci.yml`. Downgrades the architecture rules to greps. Do not use for an unattended run. See [preflight](#preflight). |
| `ALLOW_DIRTY` | unset | Start even though the target repo has uncommitted changes, accepting that the first issue's commit will contain them. |
| `ALLOW_STATIC_CREDS` | unset | Permit an unbounded run on static temporary credentials, which will expire partway through the night. See [authentication](#authentication). |
| `RETRO` | unset | Run `retro.sh` on the batch when the run finishes: a report on the harness itself, not on the code. Costs one extra invocation and is only worth it once several issues have been through. See [retrospective](#retrospective). |
| `PACK_ONLY` | unset | `retro.sh` only. Print the evidence pack and exit without calling the model. See [retrospective](#retrospective). |
| `SKIP_MODULE_CHECK` | unset | Skip the preflight module-resolution probe. Worth setting only for an air-gapped run against a settled `go.mod`, where the warning is accurate but not actionable. See [preflight](#preflight). |

### Authentication

Inference goes through **opencode**, which carries its own provider auth. Run `opencode auth login`
once (it stores a key in `~/.local/share/opencode/auth.json`), or set the provider's `*_API_KEY`
environment variable. `MODEL` and `FLASH_MODEL` must name a `provider/model` pair that `opencode
models` lists and that the machine is authenticated for. No `ANTHROPIC_API_KEY` or Bedrock wiring is
involved.

`run.sh` checks that opencode is on `PATH` and warns if `opencode auth list` comes back empty — the
latter is a warning rather than a die, because a key set in the environment may not show up in the list
until first use, and the first invocation surfaces a real auth failure quickly anyway. Both models are
checked for in the same breath as the rest of preflight.

A `GH_TOKEN` with `repo` scope is required regardless — the loop reads, comments on and closes issues,
and pushes commits.

> opencode discovers `AGENTS.md` and `CLAUDE.md` in the target repo on its own, so ArchUnitGo's
> `CLAUDE.md` pointer at `AGENTS.md` is honoured without any flag. The critics run as a read-only agent
> (`opencode/agents/readonly.md`) whose permissions are deny-on-write, not a prompt request.

### Network egress

Egress needed:

- The provider(s) that `MODEL` and `FLASH_MODEL` name — opencode resolves the endpoint from its
  provider registry, so this is wherever `opencode auth login` was pointed.
- `github.com` and `api.github.com` — for `gh`.
- Go module resolution, depending on `GOPROXY`:

| `GOPROXY` | Needs |
|---|---|
| default | `proxy.golang.org` + `sum.golang.org` |
| `direct` | the VCS host of every dependency — `go.googlesource.com` for `x/tools` — plus `sum.golang.org` |

The default is the narrower and faster of the two, which is why the image does not change it. Use
`direct` (`-e GOPROXY=direct`) only where `proxy.golang.org` is blocked; its egress set is open-ended.

The image build warms the module cache for `golang.org/x/tools`, so the first gate run does not spend the
implementer's wall clock fetching it. That reduces the module traffic but **does not remove the need for
it**: version resolution (`go get ...@latest`, `go mod tidy`) is a network lookup with no cache fallback
— it fails under `GOPROXY=off` against a fully populated cache. Once the version is pinned in `go.mod`,
`go build` is offline-capable, but the commit that first adds a dependency still needs `go mod tidy`
(its own dependencies' checksums).

The image build additionally needs `raw.githubusercontent.com` and `objects.githubusercontent.com` for
the `golangci-lint` installer, plus whatever `GOPROXY` resolves to for the cache warm — pass
`--build-arg GOPROXY=direct` if the build host is the blocked one. Neither is needed at run time.

## Testing

`test/loop_test.sh` runs `run.sh` end to end against a throwaway git repo with `opencode` and `gh` stubbed
out on `PATH`. No model, no network, no spend, a couple of seconds.

It exists because the paths that matter most are the ones a real run almost never takes — issue #1 went
through with both critics passing on the first round, which validated exactly none of the review
machinery. The scenarios:

| Scenario | What it pins down |
|---|---|
| `happy` | All three critics pass: commit, push, close, and no coverage profile left in the repo. |
| `fixround` | A critic returns `FAIL`; the finding's `problem` and `fix` text reach the fix prompt; round 2 re-reviews and lands. |
| `testcritic` | Only the third critic objects: its findings reach the fixer attributed to it, and the two that passed contribute no empty section. |
| `garbage` | A critic returns unparseable output: fail closed, with a synthesised finding, never a silent pass. |
| `abandon` | `MAX_ROUNDS` exhausted: work parked on `abandoned/issue-N`, pushed, repo reset to base, issue labelled and skipped, run carries on. Also that the issue's last invocation is a critic rather than a fixer, and that the parked branch's message records the verdict its tip was judged on. |
| `late_pass` | The critics are satisfied only by the third fix, and the issue lands on the verdict taken after it. Bounded at `MAX_ROUNDS` *rounds* instead of fixes, this same work is parked as abandoned with a green gate and every finding addressed. |
| `nodiff` | The implementer changes nothing: no critic and no fixer run, no commit, no empty branch, the issue is skipped and flagged, and the abandon line says *that* rather than blaming three rounds of review. |
| `no_push` | `NO_PUSH=1` commits locally and touches nothing remote. |
| `two_issues` | Two issues in one run: the queue advances, the second issue's base is the first one's commit, and each issue is implemented exactly once. |
| `pushfail` | A failed push stops the run and leaves the issue open: the work is committed locally, so nothing is lost, but nothing is reported done. |
| `breaker` | Consecutive abandonments stop the run before the rest of the queue is spent on a broken environment — and `MAX_CONSECUTIVE_ABANDONS=0` runs it out anyway. |
| `preflight` | A Go repo with no `.golangci.yml`, and a missing linter binary, are both fatal — and `ALLOW_NO_LINT=1` overrides both. |
| `moduleproxy` | An unresolvable module proxy warns and carries on rather than killing the run, names `GOPROXY=direct` as the fix, and the probe stays read-only. |
| `bounded` | `MAX_ISSUES` counts attempts, not landings: a queue whose first issue abandons stops at the bound instead of reaching for another issue to make the numbers up, and a landing counts the same as an abandonment. Also that the retry phase runs despite a full bound while still not admitting an issue outside it. |
| `double_critic` | A role in `DOUBLE_CRITICS` runs twice in round 1 and only round 1, the two passes get different prompts, both findings reach the fixer in the same round, the canonical verdict path holds the union while each pass's own verdict survives as evidence — and `DOUBLE_CRITICS=` switches it off. |
| `kind_pinning` | The gate's kind-pinning guard: adding a `ViolationKind` whose string value no test asserts fails the gate and names the constant; one that was already unpinned at the base commit does not, because it is not this issue's to fix; and a test comparing `Kind()` to the constant does not count as pinning it, that being the tautology the whole check is about. |
| `spend` | `MAX_SPEND` stops the run at the first issue boundary past the cap, having finished the issue that crossed it rather than interrupting it, and never starts the next one. Also that the cap is per run and not per log directory — a second run into a directory already over the cap still works — that the final line separates this run's spend from the directory's, and that a cap which does not parse as a number is fatal in preflight rather than silently no-op. |
| `retry` | An issue that cannot pass until the issue *after* it has landed — the dependency-ordered queue with a hole in it. It abandons, the next one lands over it, and the re-attempt on the batch's final tree passes: a fresh implementer with none of the first attempt's findings, both attempts' artifacts and parked branches intact side by side, and the skip list unwound because the issue no longer needs a human. `abandon` covers the other half, that an unchanged base is not re-attempted at all. |
| `retro_pack` | The evidence pack is arithmetic over hand-written artifacts: issues sorted numerically rather than lexically (`2` before `11`), landed-but-open told apart from abandoned, per-round gate outcomes and per-critic verdicts, cost summed per issue, and rounds that never ran not invented. |
| `retro` | `RETRO=1` reviews the batch that just landed and not an earlier batch's artifacts in the same log directory, writes its report to `logs/` and to stdout, and cannot fail the run. Also the one place the suite asserts that `GH_TOKEN` reaches no model invocation at all — the harness's only enforced boundary. |
| `dirty` | Uncommitted changes in the target repo are fatal before any model is invoked, the files are named, and `ALLOW_DIRTY=1` runs anyway and commits them as warned. |
| `relative_logs` | A relative `LOGS` — the invocation this README documents — still logs to the right place after the script cds into the target repo, and writes nothing into that repo. |

```bash
./test/loop_test.sh                 # all of them
./test/loop_test.sh fixround        # one
KEEP=1 ./test/loop_test.sh abandon  # leave the temp repo behind to poke at
```

The stubs are in `test/stub/`. `opencode` works out which invocation it is from the `--title` argument —
the only place `run.sh` puts the tag on the command line — captures its stdin so the test can assert on
what the harness actually put in each prompt, and edits the working tree so the diff is non-empty. It
emits the same ndjson stream `opencode run --format json` does, so run.sh's real envelope synthesis is
what the suite exercises. `timeout` is a shim: it is coreutils, present in the image but not on a stock
macOS box.

## Cost

Roughly 4–9 invocations per issue (one implementer, three critics and one fixer per round). Budget on the
order of a few dollars per issue, and the run prints the total from the JSON envelopes at the end.
`RETRO=1` adds one invocation per *batch*, not per issue, and reads artifacts rather than the repository.

**There is deliberately no per-invocation spend cap.** There was one (`--max-budget-usd`) and it was
removed: an invocation that hits a cap is killed mid-edit, which for the implementer means a half-written
package that the gate then rejects, and for a critic means no verdict at all — the fail-closed path turns
that into a `FAIL` and burns a round on a finding nobody wrote. `TIMEOUT` is the remaining stop: it
bounds a *wedged* invocation without punishing an expensive but productive one. Watch the first two or
three issues before walking away.

## Limitations

- **Sequential by design.** The issues are numbered in dependency order — #16 is meaningless without #1 —
  so parallel implementers would conflict and build against a kernel that does not exist yet.
- **Some issues are bigger than one sitting.** "Metrics: the LCOM family" and "Graph reports: the six
  output formats" are days of work. Expect a shallow first pass; the implementer is told to build the
  smallest coherent whole rather than a scaffold of stubs.
- **Large diffs are truncated** before the critics see them, and the truncation is logged as a warning
  rather than silently applied.
- **The implementer runs with full tool access.** opencode can change anything in the mounted
  workspace and reach anything the container's network policy allows. Mount only the target repo, and put
  an egress policy on the container if the host has anything else worth reaching.

## Design notes

Why the loop is shaped the way it is, one idea per line — punchline first.

### The gate runs before the reviewers

- **No model tokens are ever spent reviewing code that does not compile.** `gate.sh` runs the full check
  suite before any reviewer sees the diff, and a gate failure does not consume a review round.

### Architecture rules live in the target repo

- **They are `depguard` rules over the *resolved* import graph, not `grep`s over import lines.** An
  aliased, blank or line-wrapped import cannot slip past them — and the implementer can run exactly the
  check the gate will run. `AGENTS.md`'s dependency rules 1–3, the purity rule for
  `assertion`/`projection`/`calculation`, "globs compile to regex in one place" and the doc-comment rules
  are all expressed there.
- **Rule 4 (*nothing imports the root package*) is the one `depguard` structurally cannot express** —
  it matches path prefixes and the public surface's path is the module path itself — so the idiom critic
  owns that one by hand.

### Moving checks out of the prompts makes the critics useful

- **Both critic prompts open with the list of what the toolchain has already proven, and an instruction
  not to report any of it.** A critic spending its round on a missing doc comment is a round not spent on
  the things no linter can see — e.g. a value-receiver builder doing `append(b.xs, x)` without a clone,
  which compiles, passes every linter, passes single-branch tests, and silently corrupts one branch of a
  half-built rule whenever `cap > len`.

### The three critics do not overlap

- **Keeping them disjoint is the whole design.** All three are told to return `PASS` when their only
  findings are cosmetic — which stops the idiom critic becoming a rename generator that never approves.
  Each round, only the critics that actually found something contribute a section to the fixer's prompt.
- **The critics run concurrently**, so a third reviewer costs about a dollar a round and no wall clock.

### The test critic exists because the other two demonstrably missed this defect class

- **Issue #2:** both returned `PASS` with no findings, and the diff contained a `TestFiltersAreImmutable`
  that passed against a `Filter.Excluding` with its `slices.Clone` deleted — it asserted only that the
  *parent* was unchanged, which is true even with the bug, because appending to a nil slice always
  allocates. The test critic found it, plus a second gap nobody had noticed: the separator normalisation
  in `Filter.Matches` could be deleted with the whole suite still green, because `Pattern.Matches`
  normalises a second time and no Filter-level test ever passed a backslash. Both confirmed by mutating
  the code and re-running.
- **Issue #5 (first live run):** `WithDefaults` returned a bare `*o`, leaving `BuildTags` pointing at the
  caller's backing array. The reviewer and idiom critic passed it every round. The test critic blocked on
  the test instead of the code: the aliasing test only asserted the caller was unchanged, and the one
  field where copying is a real decision was never touched. The fix was `slices.Clone`. Three instances
  of that bug class so far, and this critic has caught all three.
- **Report everything in one pass.** Issue #5's round-2 verdict said the test never asserted that the
  resolved copy *carries* the caller's values, so `WithDefaults` dropping four of six fields was
  undetectable — equally true of the round-1 test. All three prompts now say to report everything
  blocking in one pass, because a held-back finding is a round the issue may not have.

### Round 1 doubles the test critic

- **Telling it to report everything is not the same as it doing it** — #26 still spent a round on the
  same shape of thing. So the roles in `DOUBLE_CRITICS` (test critic, by default) run twice in round 1,
  concurrently, findings unioned.
- **The two passes are not copies.** The second is told another instance is already reporting whatever it
  considers most important, and its own job is the opposite — walk the changed files and name *every*
  instance, because a finding held back for being smaller than another is a finding nobody makes.
- **Round 1 only, because the marginal round is where completeness is worth paying for** — a round-1
  finding costs a fix round; a round-3 finding costs a fix round *and* the two rounds already spent. The
  union lands at the canonical `$TAG-$role-$round.verdict.json` (`FAIL` if either pass failed), so the
  unanimity check, the fixer's prompt and `retro.sh`'s round table are unchanged; each pass's own verdict
  stays on disk as evidence. At about a dollar a pass, concurrent, it costs no wall clock and less than a
  fifth of the round it is trying to avoid.
- **The prompt is built on one mechanism — name the mutation.** For every test, state the one-line change
  that makes it fail; if you cannot, the test asserts nothing and that is a block. It is forbidden from
  reporting coverage percentages (there is no threshold in the gate) or asking for a test without naming
  what would break.

### The gate hunts reward hacking

- **The cheapest way to make `go test` pass is to stop running the tests.** `gate.sh` fails on `t.Skip`
  (unless the line carries an `ALLOW-SKIP: <reason>`), on a commented-out test function, on a module with
  no tests, and on **a test-function count lower than at the base commit** — the one thing coverage
  cannot tell you, because a deleted test takes its uncovered lines with it. `errcheck` with
  `check-blank` covers `_ =`, and `go vet`/`SA4011` cover `if false`. Both critics treat a weakened check
  as always blocking, and the fixer is told that weakening `.golangci.yml` counts as weakening the checks.
- **A test that cannot fail is the same defect wearing a passing suite.** The gate requires every
  `const Kind... = "literal"` to have its *string value* asserted by a literal somewhere in the tests.
  Comparing `Kind()` against the constant is a tautology — respell the constant and the suite stays green,
  including onto a collision with a sibling kind. The test critic found precisely this on #21, at a cost
  of $5.05 of critics and fixer, to report and fix something a `grep` decides for nothing.
- **The kind-pinning check is base-relative**, like the test count: `KindFileDependency` landed unpinned
  in #20 with all three critics passing, so a check that failed on the tree's existing holes would hand
  the next implementer somebody else's work. Forbidden is *adding* one; what is already unpinned is
  reported pre-existing and passes. Verified against real history before it shipped.

### Why abandoned issues get one retry

- **An abandonment leaves a hole in a dependency-ordered queue.** #21 (an unimplemented Files API
  terminal) was abandoned, #22–#26 landed over it, and the batch finished with five commits of kernel
  above a gap that the abandoned issue had been the prerequisite for. Hence the one re-attempt on the
  final tree.
- **The re-attempt is handed the loop's best evidence about where the issue is hard** — the findings
  still outstanding when the first attempt was abandoned — rather than starting from the issue text
  alone, which would leave that evidence on a branch nobody reads.

### Spend is bounded in dollars, not issues

- **Issues do not cost the same** — one lands in two rounds for $8, the next takes six rounds for $60, so
  a count has no ceiling anyone can state in advance (18 issues is somewhere between $150 and $1,000).
- **The cap bounds what the run *starts***, and overshooting by up to one issue is the price of never
  abandoning work mid-flight. Spend is summed from each invocation's `total_cost_usd`, counting only
  files newer than a marker touched at startup.

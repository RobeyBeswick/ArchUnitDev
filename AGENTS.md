# AGENTS.md

## What this repository is

ArchUnitDev is the **harness**, not a library. It is an unattended implement / gate / review / fix loop
that works through a target repository's open GitHub issues in number order, and lands each one on
unanimous approval from three read-only critics. The target repo is bind-mounted at `/work/repo` (or
named by `REPO`); nothing in here is the code being built.

Two `AGENTS.md` files matter when working here, and they must not be confused:

- **This one** governs changes to the harness: `run.sh`, the gates, the prompts, the images, the
  deploy scripts.
- **The target repo's `AGENTS.md`** governs the code the loop writes. The prompts point the agents at
  it and opencode discovers it on its own. Architecture rules, naming and layout for the target belong
  there, never in this repository.

The README is the full reference: every knob, every test scenario, and the design notes that record
*why* each mechanism exists. Read the relevant design note before changing a mechanism — most of them
exist because of a specific, costed failure, and the note says which.

## Layout

```text
run.sh              the loop: preflight, queue, rounds, land / park / retry, spend cap
gate.sh             dispatcher: runs gate/$TARGET_LANG.sh
gate/<lang>.sh      deterministic checks for one stack, plus the reward-hacking guards
prompts/<lang>/     implement, fix, review, idiom, tests, retro — one prompt set per stack
opencode/agents/    the read-only agent the critics and the retrospective run as
schema/verdict.json the critic verdict contract ({verdict, findings[]})
retro.sh            read-only post-batch report on the harness itself
Dockerfile          runner image for Go targets
Dockerfile.<lang>   runner image for any other stack
test/loop_test.sh   end-to-end harness tests against a throwaway repo
test/stub/          fake opencode, gh and timeout used by the tests
deploy/             EC2 provisioning (Terraform), log sync, and the scripts real runs were launched with
logs/               run output and the two state files (skipped, landed); gitignored
```

## Invariants

These are the properties the loop's correctness rests on. A change that weakens one needs a design
note in the README saying why, not just a commit.

1. **No state store.** The queue is "the lowest-numbered open issue", progress is git history, and a
   killed run is resumed by running `run.sh` again. The only state outside git and the issues is
   `logs/skipped` and `logs/landed`.
2. **The loop is language-agnostic.** Everything stack-specific lives in `gate/<lang>.sh`,
   `prompts/<lang>/` and `Dockerfile.<lang>`, selected by `TARGET_LANG`. The only stack-specific code
   allowed in `run.sh` is preflight — tool presence and dependency-resolution probes. The loop body
   does not branch on language.
3. **The gate runs before any critic,** and a gate failure goes to the fixer without costing a review
   round. No model tokens are spent on code that does not build.
4. **Fail closed.** A critic that crashes, times out or returns anything that is not a valid verdict is a
   `FAIL` with a synthesised finding — never a silent pass. Approval is unanimous.
5. **Critics are read-only by permission, not by request.** They run as `opencode/agents/readonly.md`,
   which denies edit and bash. The harness generates the diff and pipes it in; critics never touch git.
6. **`GH_TOKEN` never reaches a model invocation.** This is the harness's only enforced security
   boundary and `test/loop_test.sh` asserts it.
7. **A network failure is not a code defect.** Gate checks that need the network warn and carry on
   rather than fail, because a fixer cannot repair an unreachable registry.
8. **Spend is bounded in dollars at issue boundaries,** never per invocation. A cap that kills an
   invocation mid-edit produces half-written code and a verdict nobody wrote. `TIMEOUT` bounds only a
   wedged invocation.
9. **The gate's guards are base-relative.** Test counts and pinning checks compare against the issue's
   base commit, so an implementer is never handed a hole it did not dig.

## Adding a target language

The C# stack (commit `22eca2e` and the two after it) is the worked example. A language is:

1. `gate/<lang>.sh` — a self-contained sibling of `gate/go.sh` / `gate/csharp.sh`: build, format check,
   static analysis, tests, and that stack's spelling of every reward-hacking guard (skipped tests,
   commented-out tests, a shrinking test count, a suite with no tests, weakened tool configuration).
   Keep the guard-only mode for a repo with no project file yet, so the harness tests run without the
   toolchain installed. Prefer invoking the target repo's own configured commands (its lint config, its
   analyser level) over hard-coding rules — the architecture rules belong to the target.
2. `prompts/<lang>/` — all six files. Each critic prompt opens with what the gate has already proven and
   tells the critic not to report it. Keep the three critics disjoint: correctness, conformance to the
   target's `AGENTS.md`, and whether the tests would fail if the code were wrong.
3. `Dockerfile.<lang>` — same properties as the others: non-root `dev` user on UID 1000 (to match the
   EC2 host's bind mounts), apt over HTTPS (the host allows outbound 443 only), `gh` pinned, the
   harness copied in, toolchain caches warmed where it saves the implementer's wall clock.
4. A preflight branch in `run.sh` for the stack's tools and a dependency-resolution probe that warns
   rather than dies.
5. Test scenarios in `test/loop_test.sh` for anything stack-specific in the loop, and the new stack in
   the README's knobs, gate and egress sections.

## Shell conventions

- `set -uo pipefail`, and **never put `grep -q` on the reading end of a pipe.** `grep -q` exits on its
  first match, the writer dies of SIGPIPE (141), and `pipefail` reports the pipeline as failed. It is a
  race the writer loses only once the output outgrows the pipe buffer, so it passes on small trees and
  on macOS and then fails permanently on Linux. It once made the gate report "no test files" against a
  tree of 117 and cost four abandoned issues. Use `find ... -print -quit` into a command substitution, a
  here-string, or a `case`. The test suite bans the shape structurally.
- **Target bash 3.2**, which is what macOS ships. Expand possibly-empty arrays as
  `${arr[@]+"${arr[@]}"}`; no associative arrays, `mapfile` or `readarray`.
- `run.sh` contains a NUL byte, so plain `grep` treats it as binary. Search it with `grep -a` or `rg`.
- The loop `cd`s into the target repo. Resolve every path it derives (`LOGS`, `REPO`) to absolute
  before that, and never write inside the target repo — the loop commits it with `git add -A`.
- Blocking calls get a bound: `timeout` for invocations, `--cli-read-timeout` or a capped poll for AWS.
- Comments explain *why*, and where a mechanism exists because of a real run, they name the issue and
  what it cost. Match that density; a bare "what" comment is noise here.

## Testing

```bash
./test/loop_test.sh                 # all scenarios; no model, no network, no spend
./test/loop_test.sh fixround        # one scenario
KEEP=1 ./test/loop_test.sh abandon  # keep the temp repo to inspect
```

Every change to `run.sh`, a gate or the stubs must leave the whole suite green. A new path through the
loop gets a new scenario — the paths that matter most (fail, garbage verdict, abandon, retry) are the
ones a real run almost never takes, which is the reason the suite exists. The `opencode` stub identifies
its invocation from `--title` and captures stdin, so assert on what the harness actually put in a
prompt rather than on what it logged.

After the suite, the escalation for a real target is `PREFLIGHT_ONLY=1 ./run.sh` (free), then
`MAX_ISSUES=1 NO_PUSH=1 ./run.sh` (one issue, nothing remote).

## Diagnosing a run

- **Read the whole gate log, not its tail.** A gate failure that repeats identically across every round
  is a bug in the gate until proven otherwise — a fixer that cannot move it in several tries is being
  told something untrue.
- A run of abandonments is far more often a broken environment than several hard issues;
  `MAX_CONSECUTIVE_ABANDONS` exists for that reason.
- Re-running on a used host fails open in four ways: the skipped list already holds the issues you want,
  `HEAD` is the previous batch's tip (the loop never fetches), the host has no git credential of its own,
  and the image still holds the old harness (`COPY . /harness`). Assert all four before launching.
- Splitting one backlog across hosts leaves cross-cutting issues ("every selector", "each module")
  implemented against a tree missing the other host's work. Keep cross-cutting issues on one host, and
  run the full suite on any merged tree.

## This repository is public

Nothing account-specific lands here: no AWS account IDs, bucket names, internal hostnames, personal
paths or customer names. Real values live in `deploy/local.env` (gitignored) and are documented by
`deploy/local.env.example`. Use `123456789012`, `~/...` and similar placeholders in docs, scripts and
commit messages. Terraform state and `*.tfvars` are gitignored for the same reason.

## Working here

- Commit messages follow the existing history: a sentence-style summary of what changed and why, with
  an optional `area:` prefix (`gate:`, `runs:`, `deploy/README:`). One coherent change per commit.
- Changing a prompt is changing the loop's behaviour. Say in the commit which run, retrospective or
  finding motivated it.
- `retro.sh` proposes harness changes; it does not make them. Act on a retrospective in a separate,
  reviewed commit.
- Do not edit a target repo from here, and do not add target-specific rules to a gate or prompt that
  the target's own configuration or `AGENTS.md` could express instead.

# Run scripts

The scripts that actually launched a batch, kept because the *numbers* in them are the interesting
part. `run.sh` documents what each knob does; these document what a knob was set to on a particular
night and what happened as a result. They are host-specific and bucket-specific on purpose — a
generalised version would have to drop exactly the detail that makes them worth keeping.

They are not part of the harness. Nothing in `run.sh`, `gate.sh` or the tests reads them.

## The 15 August intervention

The 14 August batch (`#27`-`#44`, `MAX_ROUNDS=4 TIMEOUT=45m MAX_SPEND=600`) landed `#27`-`#29`, `#32`,
`#33` and abandoned `#30` and `#31`. It was stopped at `#34` and the remainder re-run with wider
limits, on two hosts.

### Why `#30` and `#31` failed

Not a livelock, and not a defect in the loop.

Both implementers hit the 45m step timeout (`rc=124`, `aborted_streaming`, ~$17 each) and were cut off
mid-change. That left an oversized partial diff, so round 1 went to the gate rather than to the
critics — costing a whole fix cycle before any review happened, three instead of four. Both then ran
out of rounds while the test critic was still finding *new, real* mutation-survival holes each round:
`#31` was converging (3 → 2 → 1 → 1 findings), `#30` was flat at 2. Neither was stuck; both were
short of runway.

For contrast, `#33` landed in two rounds for $13. Wide limits cost nothing on the issues that do not
need them.

### Why the re-attempt could not happen on its own

`RETRY_ABANDONED` gives an abandoned issue one more attempt at the end of the run — but the retry
phase is only reached when the queue drains or `MAX_ISSUES` is hit. A run that ends on `MAX_SPEND`
(`break`) or the consecutive-abandon breaker (`die`) skips it entirely. At ~$38/issue the batch was
going to stop around `#41` on its $600 cap, by exactly that path. So `#30` and `#31` were never going
to get the second attempt the flag appeared to promise.

Two things follow, and both are in this directory:

- `MAX_SPEND` is worse than useless on an unattended run whose failures matter. The issues a capped
  run abandons are precisely the ones it then denies a retry. It is set to 0 in both scripts.
- `CARRY_FINDINGS` (added in the same change as these scripts) lets a *first* attempt on a fresh host
  read the outstanding findings of an attempt it did not make. The verdicts were sitting unread on
  disk — ~$36 of review across the two issues — while the alternative was paying to re-derive them.

### The two hosts

| | host | queue | limits |
|---|---|---|---|
| A | `archunitdev-retry`, m5.xlarge | `#30`, `#31` | 10 rounds, 120m, no caps, `CARRY_FINDINGS=1` |
| B | `archunitdev-loop`, resized to m5.xlarge | `#34` (if abandoned) and `#35`-`#44` | 10 rounds, 120m, no caps, `MAX_CONSECUTIVE_ABANDONS=3` |

Two hosts rather than one queue on one host because Slices (`#30`/`#31`) and Metrics (`#33`-`#37`) are
independent features, so the wall-clock saving is real and the merge cost is not. It is not free: both
hosts fork from `da23b32`, so combining them afterwards is a merge that will most likely conflict in
`archunit.go`. That is a deliberate trade, not an oversight.

The abandon tripwire is on for B and off for A, and the asymmetry is the point: A's entire queue is
issues that have *already* been abandoned once, so the tripwire would fire on the expected outcome
rather than on a broken environment.

`#41`, `#42` and `#44` are held off B's queue until the two trees are merged. The rest of the split
costs only a merge — `#35`-`#37` are Metrics, and `#38`-`#40` are cross-cutting but name no feature.
These three describe or ship the library *as a whole*, against a tree with no Slices in it: `#41` asks
for "one example per module" and would omit one, `#42` builds the site from that README, `#44` tags a
release of an incomplete tree. Work that has to be redone is worse than work not yet done.

### The gate bug that made all of this look like a runway problem

The wider limits were relaunched at 09:30 and by 11:32 host B had abandoned `#35`, `#36` and `#37` and
tripped its abandon breaker; host A had abandoned `#31` at 10:14. Every one of them failed the same
way: `gate failed` on all eleven rounds, with the gate log showing build, vet, lint, the whole suite
and 100% coverage passing before

```
--- at least one test exists
VIOLATION: the module has no test files at all.
```

The check was `! find . -name '*_test.go' | grep -q .`. `grep -q` exits on its first match and closes
the pipe, `find` dies of SIGPIPE with 141, `set -o pipefail` makes 141 the pipeline's status, and the
`!` turns a *successful* match into a violation. Measured in the container on the real tree: 117 test
files, pipeline exit 141. Nothing an implementer could write would ever satisfy it.

It is a race the writer has to lose, which is why it passed for months and then failed permanently: on
a small tree `find` finishes inside the pipe buffer and exits 0. `looks_like_network_trouble` had the
same shape with the defect pointing the other way — a long enough failure log outlasts the buffer, so
a network outage would have been reported to the fixer as a code defect.

Three things this cost, and one it did not:

- Four issues and about $80, ten fix rounds each, across two hosts.
- A retrospective that blamed the runway, because nobody read the gate log past the passing tests. The
  `#26` and 14 August retros both did the same thing. **A gate failure that repeats identically across
  rounds is a gate bug until proven otherwise** — a fixer that cannot move the needle in ten tries is
  not failing to fix, it is being told something untrue.
- The 14 August batch's `#30`/`#31` abandonment, which was read as a timeout problem, and partly was:
  `#30` really did need 7 rounds. But `#31` was almost certainly this.

What it did not cost: the rest of the backlog. `MAX_CONSECUTIVE_ABANDONS=3` stopped host B at `#37`
rather than letting it burn `#38`, `#39`, `#40` and `#43` identically, and the message it printed named
the right suspect — "far more often a broken environment ... than several independently hard issues".
The tripwire was the only part of the system that diagnosed this correctly.

The parked work turned out to be intact. `abandoned/issue-35`, `-36` and `-37` all pass the fixed gate
with zero violations, which is the confirmation that the implementations were complete and only the
check was wrong. They were re-run from scratch anyway rather than salvaged: resuming from a parked
branch is a harness feature that does not exist, and inventing one while two hosts sat idle was the
worse trade when the re-run is $80 and cost is not the constraint.

### What the wider limits bought

`#30` landed on the first attempt under them: 7 rounds, all three critics passing, $26. Six of those
rounds went to the gate before the diff was even reviewable — under the old `MAX_ROUNDS=4` it would
have been abandoned a second time, at roughly the same cost. The runway was the whole problem.

### Getting the work between hosts

The batch runs `NO_PUSH=1`, so its commits exist only on the volume that made them. The transport is a
`git bundle` through the bucket's `handoff/` prefix — a prefix added for this, rather than granting
`s3:GetObject` on `loop/*`, because "the loop cannot read its own logs back" is a property worth
keeping. See the comment on `aws_iam_role_policy.handoff`.

### Operational notes

- Git refuses to work in a repository owned by another user, so every git call goes through
  `sudo -u ec2-user`. Using `safe.directory` instead would let root write to the tree, and then the
  container (uid 1000) fails on its first commit against root-owned objects in `.git`.
- Resizing an instance is an in-place update that **stops and starts** it. Under `NO_PUSH` the volume
  holds commits that exist nowhere else. Resize between batches, never during one.
- The 14 August batch's own final upload targets an `ec2/` prefix the instance role cannot write, so
  it fails silently after a long run. The work survives anyway: the bundle is written into the log
  directory first, and log-sync ships that. Both scripts here upload to `handoff/` instead.
- `run.sh` contains a NUL byte (inside a jq `unique_by(.file + "\x00" + .problem)`), which makes plain
  `grep` treat it as binary and print nothing. Use `grep -a`.
- Restarting a batch over a log directory a previous run used made log-sync refuse to start, and so
  refuse to launch: `logs/latest` is a symlink to the *container's* path for the current debug log, and
  `aws s3 sync` skips a dangling symlink with a warning but still exits 2. `--exclude` does not help —
  the warning comes from the directory walk, before filters apply. Fixed with `--no-follow-symlinks`
  (exit 2 → 0, measured on the host). A fresh host never sees it: with no `latest` yet the fatal first
  sync succeeds, and every later failure lands in the warn-and-continue path.

## The 24 September brute force: ArchUnitSharpTest `#38` and `#39` on Opus 5.5

Script: `sharp-opus55-bruteforce.sh`. This follows on from the Opus 5.5 benchmark run
(`RUN_ID sharp-opus55-20260923T103101Z`), which ran at the benchmark settings: `MAX_ROUNDS=3 TIMEOUT=60m
VARIANT=high MAX_CONSECUTIVE_ABANDONS=2 RETRY_ABANDONED=1`, with no spend cap.

### What the benchmark left

Between 2026-09-23 10:30Z and 2026-09-24 01:33Z it landed `#1`-`#37` on a $286.96 ledger. It then
abandoned `#38` (pattern exclusions, `except`) and `#39` (logging) back to back, which tripped the
two-abandon breaker. `#40`-`#46` were never attempted; `#44` was held back from the start.

The breaker was wrong this time. What it guards against, a broken environment, was not there: the gate
was clean in every round of both issues, and every round's findings were new and real. On `#38` they
were a doc example the folder rules contradict, and tests that cannot tell the sibling matcher apart.
On `#39` they were a `Release(fullPath)` in a `catch` whose deletion no test catches, and doc remarks
claiming file sharing that `FileShare.Read` does not give. Both issues were converging when they ran
out of runway, which is the `#30`/`#31` pattern from 15 August. And because the breaker calls `die()`,
the `RETRY_ABANDONED` phase that would have given each issue a second attempt never ran, as it did not
on 15 August either.

### What was changed, and what deliberately was not

The extra power is **attempts, rounds and time**. Nothing else changes:

| | benchmark | brute force (phase A: `#38`, then `#39`) |
|---|---|---|
| attempts per issue | 1 (plus a retry that never ran) | up to 5, each a fresh `run.sh` |
| `MAX_ROUNDS` | 3 | 15 |
| `TIMEOUT` (per invocation) | 60m | 240m |
| `CARRY_FINDINGS` | off | on: each attempt starts from the last one's outstanding findings |
| `MAX_CONSECUTIVE_ABANDONS` | 2 | 0 |
| model, `VARIANT`, prompts, gate, critics | Opus 5.5, `high` | **unchanged** |

The model, the reasoning effort, the prompts and the approval bar are all unchanged. An issue still lands
only on a unanimous PASS over a clean gate. So if either issue lands, the only difference from the
benchmark is how long the loop was allowed to try, and that is the thing being measured.

`VARIANT=max` was tried first and dropped. Its first implement died three seconds in (see below), and
raising reasoning effort would make the model on these two issues a different one from the model on
the other 37. Everything stays on `high`.

Phase B then runs `#40`-`#46` at exactly the benchmark's settings, in the benchmark's own log
directory, so the report reads one ledger. There are two deviations, both small:

- `MAX_CONSECUTIVE_ABANDONS=0`. The breaker has already fired once on hard issues, and a second false
  stop costs another night.
- `#38` and `#39` are held back if phase A did not land them, since they have had their attempts.

### How the attempts are kept apart

Every attempt is its own `run.sh` invocation with its own log directory,
`logs/bruteforce/<N>-attempt-<k>/`. `run.sh` names its files by issue, role and round, so a second run
over the same directory would overwrite the first attempt's `.json`/`.jsonl` files, and their token
data would be gone for good. An attempt's `skipped` holds every other open issue, which is how a single
run is pointed at exactly one issue. An abandoned attempt's branch is renamed
`abandoned/issue-<N>-bruteforce-<k>` and pushed before the next attempt reuses the name. The
benchmark's `abandoned/issue-<N>` is left as it was.

### The crash that is not an attempt

In each of the first three launches, the first implement in a fresh container exited `rc=1` three
seconds in:

- opencode reported `"Unexpected server error. Check server logs for details."`
- the cost was $0 and there were no turns
- opencode's own log shows the session created and its event stream connected, then nothing, not even
  step 0

`run.sh` then did what it should do with an empty diff. It abandoned the issue and posted "could not
get this past review in 15 rounds" on it, although no model had looked at the issue. The next
invocation in the same container ran normally.

The same prompt, sent to a fresh `--rm` container outside the loop, also worked, so the cause is still
open. The script does not count this as an attempt. When an implement fails with exactly that
signature (`cost=$0 turns=0`, then "the implementer changed nothing on round 1"), the script:

- sets the directory aside as `crashed-<N>-attempt-<k>-<i>`
- deletes the comment the non-attempt posted
- runs the attempt again, giving up after three crashes in a row

On the launch of 2026-09-24 11:58Z the first implement crashed exactly as before. The crash was
caught, and the re-run implement was at $2.12 and 80 events six minutes later.

The other directories under `logs/bruteforce/` are the aborted launches, kept for the record:
`aborted-variant-max-38-attempt-1` (the `max` launch), `crashed-38-attempt-1-launch2`, and
`aborted-stopped-38-attempt-2-launch2`. The last one was stopped by hand while its launch was being
diagnosed, before the crash handling existed. None of them landed any code or parked a branch, and
their ledgers are $0 apart from the few minutes of the stopped attempt.

### Results

Both issues landed on their first brute-force attempt. Neither needed more than 2 of the 15 rounds,
and no invocation came near the 240m timeout. Then phase B cleared the rest of the backlog without an
abandonment. The container exited cleanly at 2026-09-24 15:19:54Z, 3h21m after launch. `#44` (Publish
to NuGet) is the only open issue, and it was held back on purpose.

| issue | attempt | rounds | implement | issue total |
|---|---|---|---|---|
| `#38` pattern exclusions | 1 of 5 | 2: tests FAIL, then all PASS | $8.66, 78 turns | $13.73 |
| `#39` logging | 1 of 5 | 2: tests FAIL, then all PASS | $11.09, 125 turns | $17.21 |

Phase B ran at the benchmark's settings (3 rounds, 60m):

| issue | rounds | issue total |
|---|---|---|
| `#40` dogfood the architecture rules | 2 | $5.63 |
| `#41` README | 1 | $5.40 |
| `#42` documentation site | 3 | $13.86 |
| `#43` CI | 1 | $1.29 |
| `#45` test suite green across the CI matrix | 1 | $0.72 |
| `#46` `Metrics<T>()` silent pass | 1 | $1.90 |
| **phase B** | | **$28.80** |

The CI on the final tip (`fa896d9`) passes: "Build, lint and test" and "Build the site" both succeed,
and "Publish to GitHub Pages" is skipped.

What the whole backlog cost:

| | cost |
|---|---|
| benchmark (`#1`-`#37`, and the abandoned first attempts at `#38`/`#39`) | $286.96 |
| brute force `#38` + `#39` | $30.94 |
| aborted and crashed launches | $0.15 |
| phase B (`#40`-`#43`, `#45`, `#46`) | $28.80 |
| **45 of 46 issues landed** | **$346.85** |

What this says about the benchmark's two abandonments: they were a runway problem, not a capability
problem. Each issue needed one more round than `MAX_ROUNDS=3` allowed it. `CARRY_FINDINGS` mattered
here: the re-implementation started from the findings the benchmark's third round had left
outstanding, so it did not rediscover them. On the second attempt, the $30.94 it took to land both issues
was about one tenth of the benchmark's total, while 15 rounds and 240m, which cost nothing unless
used, went almost entirely unused. The breaker was the part that was wrong. With it off and a retry
available, the benchmark settings alone would most likely have landed both issues in the same night.

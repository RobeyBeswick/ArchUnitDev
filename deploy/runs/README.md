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

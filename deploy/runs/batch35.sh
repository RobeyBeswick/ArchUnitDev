#!/bin/bash
#
# The rest of the backlog, with limits that fit it. Everything from #35 to #44, plus #34 if it
# abandoned, and not #30 or #31 — those are being re-attempted on the other host.
#
# What the first batch taught, in the order it matters:
#
#   - 45m is not enough for the big issues. #30 and #31 were both cut off mid-implement (rc=124,
#     ~$17 each), which sent an oversized partial diff to the gate and burned a round before any
#     critic saw the work. Both then ran out of fix rounds while the test critic was still finding
#     real mutation-survival holes — #31 was converging, 3 -> 2 -> 1 -> 1. So 120m and 10 fixes.
#   - The spend cap is worse than useless here. MAX_SPEND ends the run with `break`, which skips the
#     retry phase — so the issues abandoned by a capped run are exactly the ones that never get their
#     second attempt. At ~$38/issue the first batch would have stopped around #41 by that path,
#     leaving #42-#44 untouched and its own abandonments unretried. MAX_SPEND=0.
#   - Most issues do not need any of this. #33 landed in two rounds for $13. Wide limits cost nothing
#     on the issues that do not use them; they only stop the hard ones failing on the clock.
#
# MAX_CONSECUTIVE_ABANDONS=3 stays, unlike on the other host. There the whole queue was
# already-abandoned issues, so the tripwire would fire on the expected outcome. Here the queue is
# fresh work and three abandonments in a row really is more likely a broken environment — expired
# credentials, a wedged toolchain, a model outage — than three independently impossible issues.
#
# Run as root:  sudo /home/ec2-user/batch35.sh
#
set -uo pipefail

# The log bucket's name is account-specific, so it is not written down in this repository. The
# bootstrap wrote it to /etc/profile.d, which a `sudo` of a script does not source — hence reading it
# here, and hence BUCKET staying overridable for a run driven from anywhere else.
[ -r /etc/profile.d/archunitdev.sh ] && . /etc/profile.d/archunitdev.sh
BUCKET="${BUCKET:-${S3_LOGS:+${S3_LOGS%/loop}}}"
[ -n "$BUCKET" ] || { echo "REFUSING: no log bucket. Set BUCKET=s3://... or run where /etc/profile.d/archunitdev.sh exists." >&2; exit 1; }
REGION=us-east-1
H=/home/ec2-user

say() { printf '%s  batch35: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if docker ps --format '{{.Command}}' | grep -q 'run\.sh'; then
  say "REFUSING: a loop is already running"
  exit 1
fi
if [ -n "$(sudo -u ec2-user git -C "$H/ArchUnitGo" status --porcelain)" ]; then
  say "REFUSING: the target repo has uncommitted changes"
  exit 1
fi
if ! sudo -u ec2-user git -C "$H/ArchUnitGo" rev-parse --abbrev-ref HEAD | grep -qx main; then
  say "REFUSING: the target repo is not on main"
  exit 1
fi

# The queue is "open issues, minus landed, minus skipped", and nothing is closed because the batch runs
# NO_PUSH. Three corrections to make before that arithmetic gives the right answer:
#
#   30 and 31 must stay skipped. They are being re-attempted on the other host, against the same base;
#   both hosts implementing them would produce two divergent versions of the same feature.
for n in 30 31; do
  grep -qx "$n" "$H/logs/skipped" || echo "$n" >> "$H/logs/skipped"
done
#   41, 42 and 44 must be held until the two hosts are merged. Splitting the backlog across hosts costs
#   nothing on the issues that only touch their own feature — 35-37 are Metrics, 38-40 are cross-cutting
#   but name no feature, so at worst they conflict in the merge. These three are different in kind: each
#   describes or ships the library *as a whole*, and this host's tree has no Slices in it. #41 asks for
#   "one example per module" and would silently omit a module; #42 builds the site from it; #44 tags a
#   release of a tree that is missing a feature. All three would have to be redone after the merge, so
#   running them now buys nothing and costs a plausible-looking wrong answer.
#
#   This was applied by hand before launch on the night, not by this script — recorded here because the
#   queue is what makes these scripts worth keeping. `logs/HELD.txt` says the same thing on the host.
for n in 41 42 44; do
  grep -qx "$n" "$H/logs/skipped" || echo "$n" >> "$H/logs/skipped"
done
#   34 must not be skipped, if the first batch abandoned it. It was abandoned under the old limits, and
#   giving it the new ones is the entire point of restarting. Its verdicts stay on disk, so
#   CARRY_FINDINGS below hands the previous attempt's findings to the new one.
#   `|| true` and then a verification, not `&& mv`: `grep -vx 34` over a file whose only line is `34`
#   prints nothing and exits 1, so `grep ... && mv` skips the mv and leaves the number skipped while
#   still narrating success. It cost a three-second run with an empty queue when the relaunch script
#   inherited this line. See deploy/runs/relaunch-after-gate-fix.sh.
if grep -qx 34 "$H/logs/skipped"; then
  grep -vx 34 "$H/logs/skipped" > "$H/logs/skipped.tmp" || true
  mv "$H/logs/skipped.tmp" "$H/logs/skipped"
  chown ec2-user:ec2-user "$H/logs/skipped"
  grep -qx 34 "$H/logs/skipped" && { say "REFUSING: could not un-skip #34"; exit 1; }
  say "#34 was abandoned by the first batch — removed from skipped so it is re-attempted with the new limits"
fi
say "skipped: $(tr '\n' ' ' < "$H/logs/skipped")"
say "landed:  $(tr '\n' ' ' < "$H/logs/landed")"

if ! grep -q 'CARRY_FINDINGS' "$H/ArchUnitDev/run.sh"; then
  say "REFUSING: the built harness has no CARRY_FINDINGS — wrong branch or a stale image"
  exit 1
fi

export GH_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id archunitdev/gh-token --query SecretString --output text)"
[ -n "$GH_TOKEN" ] || { say "REFUSING: the GitHub token came back empty"; exit 1; }

say "starting the rest of the backlog: MAX_ROUNDS=10 TIMEOUT=120m no spend cap, CARRY_FINDINGS=1"
sudo -u ec2-user --preserve-env=GH_TOKEN docker run --rm \
  -e GH_TOKEN -e NO_PUSH=1 -e RETRO=1 \
  -e MAX_ISSUES=0 -e MAX_ROUNDS=10 -e TIMEOUT=120m \
  -e MAX_SPEND=0 -e MAX_CONSECUTIVE_ABANDONS=3 -e RETRY_ABANDONED=1 \
  -e CARRY_FINDINGS=1 \
  -v "$H/ArchUnitGo:/work/repo" \
  -v "$H/logs:/work/logs" \
  archunitdev >> "$H/logs/loop.out" 2>&1
rc=$?
say "the batch has exited (rc=$rc)"

# No `set -e` above: the commits are the point, they exist only on this volume, and they have to be got
# off it whatever the loop's exit status was. handoff/ rather than the ec2/ prefix the first batch used
# — the instance role has no permission there, so that upload failed silently at the end of a long run.
sudo -u ec2-user git -C "$H/ArchUnitGo" bundle create "$H/logs/work-35-44.bundle" --all \
  && say "bundled $(sudo -u ec2-user git -C "$H/ArchUnitGo" rev-list --count origin/main..main) unpushed commit(s)"
aws s3 cp "$H/logs/work-35-44.bundle" "$BUCKET/handoff/work-35-44.bundle" --region "$REGION" \
  && say "bundle uploaded"

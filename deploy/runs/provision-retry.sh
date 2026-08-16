#!/bin/bash
#
# Prepare the re-attempt host: the harness, the target repo as the loop host left it, the findings the
# first attempts paid for, and a queue pinned to the two issues the main batch abandoned.
#
# Everything arrives through the handoff/ prefix rather than from a git remote. It has to for the
# target repo — the batch runs NO_PUSH, so its commits exist only on the loop host's volume and S3 is
# the only place they can be reached from — and taking the harness the same way means this script
# needs no GitHub token at all. The token is fetched once, at launch, by retry3031.sh.
#
# Run as root, once:  sudo /home/ec2-user/provision-retry.sh
#
set -uo pipefail

BUCKET=s3://<log-bucket>
REGION=us-east-1
H=/home/ec2-user
# The loop host's main when the bundle was taken: issue #32 landed. Asserted rather than assumed,
# because a re-attempt against the wrong base is the one failure that produces plausible commits.
EXPECT_MAIN=da23b32a0bdfd0b90cc05c73ffbfed5297eaaa6c

say() { printf '%s  provision: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { say "FAILED: $*"; exit 1; }
# git refuses to work in a repository owned by another user, so every git call here goes through the
# owner. Doing it with safe.directory instead would let root write to the tree, and then the container
# (which runs as uid 1000) finds root-owned objects in .git and fails on its first commit.
ec2() { sudo -u ec2-user "$@"; }

# --- the harness, at the commit that can carry findings across runs -------------------------------
say "fetching the harness bundle"
aws s3 cp "$BUCKET/handoff/harness.bundle" "$H/harness.bundle" --region "$REGION" --only-show-errors \
  || die "could not fetch the harness bundle"
chown ec2-user:ec2-user "$H/harness.bundle"
ec2 git -C "$H/ArchUnitDev" fetch "$H/harness.bundle" '+refs/heads/*:refs/remotes/handoff/*' \
  || die "could not fetch from the harness bundle"
ec2 git -C "$H/ArchUnitDev" checkout -B retry-30-31 handoff/worktree-retry-host-30-31 \
  || die "could not check out the harness branch"
say "harness at $(ec2 git -C "$H/ArchUnitDev" log --oneline -1)"
grep -q 'CARRY_FINDINGS' "$H/ArchUnitDev/run.sh" \
  || die "the checked-out run.sh has no CARRY_FINDINGS — wrong branch, and the findings would be silently ignored"

# --- the target repo, as the loop host left it ----------------------------------------------------
# main at #32, and both abandoned attempts as local branches. The abandoned branches are not what
# gets implemented — a re-attempt starts clean — but they are what the carried findings refer to, and
# a human comparing the two attempts needs them here.
say "fetching the target-repo bundle"
aws s3 cp "$BUCKET/handoff/archunitgo-30-31.bundle" "$H/parked.bundle" --region "$REGION" --only-show-errors \
  || die "could not fetch the target-repo bundle"
chown ec2-user:ec2-user "$H/parked.bundle"
ec2 git -C "$H/ArchUnitGo" fetch "$H/parked.bundle" '+refs/heads/*:refs/remotes/parked/*' \
  || die "could not fetch from the target-repo bundle"
ec2 git -C "$H/ArchUnitGo" reset --hard parked/main || die "could not reset main to the parked tree"
ec2 git -C "$H/ArchUnitGo" branch -f abandoned/issue-30 parked/abandoned/issue-30 || die "branch 30"
ec2 git -C "$H/ArchUnitGo" branch -f abandoned/issue-31 parked/abandoned/issue-31 || die "branch 31"

head=$(ec2 git -C "$H/ArchUnitGo" rev-parse HEAD)
[ "$head" = "$EXPECT_MAIN" ] \
  || die "main is $head, expected ${EXPECT_MAIN:0:7} — this is not the tree the batch had reached"
[ -z "$(ec2 git -C "$H/ArchUnitGo" status --porcelain)" ] \
  || die "the target repo is dirty after the reset"
say "target repo on $(ec2 git -C "$H/ArchUnitGo" rev-parse --abbrev-ref HEAD) at ${head:0:7}, $(ec2 git -C "$H/ArchUnitGo" rev-list --count origin/main..main) unpushed commit(s)"

# --- the findings, where CARRY_FINDINGS can read them ---------------------------------------------
# run.sh looks for $LOGS/<issue>-<critic>-<round>.verdict.json, counting rounds down from MAX_ROUNDS+1
# and taking the highest round that found anything. Both issues were parked after round 5 with the
# test critic still failing and review and idiom passing, so round 5 is what gets carried.
say "placing the verdicts from the abandoned attempts"
mkdir -p "$H/logs"
aws s3 cp "$BUCKET/handoff/verdicts/" "$H/logs/" --recursive --region "$REGION" --only-show-errors \
  || die "could not fetch the verdicts"
chown -R ec2-user:ec2-user "$H/logs"
for n in 30 31; do
  c=$(ls "$H"/logs/$n-*.verdict.json 2>/dev/null | wc -l)
  [ "$c" -gt 0 ] || die "no verdicts for #$n — CARRY_FINDINGS would carry nothing, silently"
  say "  #$n: $c verdict file(s)"
done

# --- the queue -------------------------------------------------------------------------------------
# Nothing is closed (the batch runs NO_PUSH), so all of #11-#44 is still open and the queue is
# "open issues, minus landed, minus skipped". Seeding landed with everything except 30 and 31 is what
# pins this host to those two and stops it wandering into work the main loop is still doing.
say "pinning the queue to #30 and #31"
: > "$H/logs/skipped"
for i in $(seq 11 44); do case $i in 30 | 31) ;; *) echo "$i" ;; esac; done > "$H/logs/landed"
chown ec2-user:ec2-user "$H/logs/landed" "$H/logs/skipped"
say "landed seeded with $(wc -l < "$H/logs/landed") issue(s) — queue is #30 then #31"

# --- the image -------------------------------------------------------------------------------------
say "building the image (several minutes)"
docker build -t archunitdev "$H/ArchUnitDev" > "$H/build.log" 2>&1 \
  || { tail -30 "$H/build.log"; die "docker build — full output in $H/build.log"; }
say "image built"

# --- log shipping ----------------------------------------------------------------------------------
# Its own RUN_ID, so this host's artifacts cannot overwrite the main run's: both write to the same
# bucket, and the filenames (30-tests-5.verdict.json and so on) would collide exactly.
say "starting log-sync"
S3_LOGS="$BUCKET/loop" RUN_ID=retry-30-31 LOGS="$H/logs" \
  setsid nohup "$H/ArchUnitDev/deploy/log-sync.sh" > "$H/log-sync.out" 2>&1 &
sleep 20
grep -q 'first sync done' "$H/log-sync.out" \
  || { cat "$H/log-sync.out"; die "log-sync could not get its first sync away"; }
say "log-sync running -> $BUCKET/loop/retry-30-31"

say "ready. Launch with: sudo $H/retry3031.sh"

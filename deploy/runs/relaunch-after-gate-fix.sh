#!/bin/bash
#
# Re-run the issues the broken gate threw away, on either host.
#
# On 15 August #31, #35, #36 and #37 were all abandoned with "gate failed" on every round of every
# attempt. That was not the implementations: gate.sh's "at least one test exists" check was written as
# `! find . -name '*_test.go' | grep -q .`, and under `set -o pipefail` a successful `grep -q` closes
# the pipe, find dies of SIGPIPE with 141, and the pipeline reports 141 — so the check declared a tree
# with 117 test files to have none, on every round, unfixably. Ten fix rounds each, about $80.
#
# Two things worth keeping in mind about that failure, because they shaped this script:
#
#   - MAX_CONSECUTIVE_ABANDONS did its job. Three in a row on host B stopped the run at #37 instead of
#     letting it burn #38, #39, #40 and #43 the same way. It is left at 3 for exactly that reason: the
#     tripwire is what turned an unbounded loss into a bounded one, and the message it printed named
#     the right suspect ("far more often a broken environment ... than several independently hard
#     issues") even though the retrospective went looking at the runway instead.
#   - CARRY_FINDINGS has nothing to carry here. The critics never ran on these issues — the gate never
#     passed — so there are no verdicts on disk. It is set anyway, because it is free when there is
#     nothing to find and #31's earlier attempt under the old limits *did* leave findings.
#
# Usage, as root, on either host:
#   HOST=a sudo -E /home/ec2-user/relaunch-after-gate-fix.sh    # #31
#   HOST=b sudo -E /home/ec2-user/relaunch-after-gate-fix.sh    # #35-#37, then #38-#40, #43
#
set -uo pipefail

BUCKET=s3://<log-bucket>
REGION=us-east-1
H=/home/ec2-user
HOST="${HOST:?set HOST=a or HOST=b}"

say() { printf '%s  relaunch-%s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$HOST" "$*"; }
die() { say "REFUSING: $*"; exit 1; }
ec2() { sudo -u ec2-user "$@"; }

case "$HOST" in
  a) UNSKIP="31"             ; ABANDONS=0 ; RUN_ID=20260815-a-31-refix   ;;
  b) UNSKIP="35 36 37"       ; ABANDONS=3 ; RUN_ID=20260815-b-refix      ;;
  *) die "HOST must be a or b" ;;
esac

docker ps --format '{{.Command}}' | grep -q 'run\.sh' && die "a loop is already running"
[ -z "$(ec2 git -C "$H/ArchUnitGo" status --porcelain)" ] || die "the target repo is dirty"
ec2 git -C "$H/ArchUnitGo" rev-parse --abbrev-ref HEAD | grep -qx main || die "the target repo is not on main"

# --- the fixed harness ------------------------------------------------------------------------------
aws s3 cp "$BUCKET/handoff/harness.bundle" "$H/harness.bundle" --region "$REGION" --only-show-errors \
  || die "could not fetch the harness bundle"
chown ec2-user:ec2-user "$H/harness.bundle"
ec2 git -C "$H/ArchUnitDev" fetch -q "$H/harness.bundle" '+refs/heads/*:refs/remotes/handoff/*' \
  || die "could not fetch from the bundle"
ec2 git -C "$H/ArchUnitDev" checkout -q -B refix handoff/worktree-retry-host-30-31 \
  || die "could not check out the harness branch"
say "harness at $(ec2 git -C "$H/ArchUnitDev" log --oneline -1)"

# The whole point of this run. A rebuild that silently reused a cached layer would repeat the night, so
# assert the fix is in the source and then again in the image that gets run.
grep -q 'print -quit' "$H/ArchUnitDev/gate.sh" || die "gate.sh is not the fixed one"
docker build -t archunitdev "$H/ArchUnitDev" > "$H/build-refix.log" 2>&1 \
  || { tail -20 "$H/build-refix.log"; die "docker build — see $H/build-refix.log"; }
docker run --rm --entrypoint grep archunitdev -q 'print -quit' /harness/gate.sh \
  || die "the built image does not contain the gate fix"
say "image rebuilt and carries the fix"

# --- the queue --------------------------------------------------------------------------------------
# The abandoned numbers go back in. Their work is parked on abandoned/issue-N branches and is left
# there untouched: it is evidence, and the branches cost nothing.
#
# `|| true` on the grep, and then the removal is *verified* rather than announced. `grep -vx 31` over a
# file whose only line is `31` prints nothing and exits 1, so the obvious
# `grep -vx "$n" f > tmp && mv tmp f` silently skips the mv and leaves the number skipped — while the
# `say` below it still claims success. That is how the first attempt at this relaunch ended: it
# reported "#31 un-skipped", started a run with an empty queue, and exited 0 in three seconds. It is
# the same mistake as the gate bug this script exists to recover from: a grep's exit status standing in
# for something it does not mean.
for n in $UNSKIP; do
  grep -qx "$n" "$H/logs/skipped" || continue
  grep -vx "$n" "$H/logs/skipped" > "$H/logs/skipped.tmp" || true
  mv "$H/logs/skipped.tmp" "$H/logs/skipped"
  grep -qx "$n" "$H/logs/skipped" && die "could not un-skip #$n — it is still in $H/logs/skipped"
  say "#$n un-skipped — it was abandoned by the broken gate, not by its own difficulty"
done
chown ec2-user:ec2-user "$H/logs/skipped"
say "skipped: $(tr '\n' ' ' < "$H/logs/skipped")"

# An empty queue is a silent no-op: run.sh exits 0 in a couple of seconds having done nothing, which
# reads exactly like success in a log nobody watches. Every number this run exists to attempt must
# actually be attemptable before the token spend starts.
for n in $UNSKIP; do
  grep -qx "$n" "$H/logs/landed" && die "#$n is in landed — nothing to re-attempt, check the queue by hand"
done

# --- log shipping ------------------------------------------------------------------------------------
# A fresh prefix: these issues already have logs under the previous prefix, and those logs are the
# evidence for the diagnosis above. Overwriting them in place would destroy the record.
pkill -f 'log-sync.sh' 2>/dev/null && say "stopped the previous log-sync"
sleep 2
S3_LOGS="$BUCKET/loop" RUN_ID="$RUN_ID" LOGS="$H/logs" \
  setsid nohup "$H/ArchUnitDev/deploy/log-sync.sh" > "$H/log-sync-$RUN_ID.out" 2>&1 &
sleep 25
grep -q 'first sync done' "$H/log-sync-$RUN_ID.out" \
  || { cat "$H/log-sync-$RUN_ID.out"; die "log-sync could not get its first sync away"; }
say "log-sync -> $BUCKET/loop/$RUN_ID"

# --- go ----------------------------------------------------------------------------------------------
export GH_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id archunitdev/gh-token --query SecretString --output text)"
[ -n "$GH_TOKEN" ] || die "the GitHub token came back empty"

say "starting: MAX_ROUNDS=10 TIMEOUT=120m no spend cap, MAX_CONSECUTIVE_ABANDONS=$ABANDONS"
sudo -u ec2-user --preserve-env=GH_TOKEN docker run --rm \
  -e GH_TOKEN -e NO_PUSH=1 -e RETRO=1 \
  -e MAX_ISSUES=0 -e MAX_ROUNDS=10 -e TIMEOUT=120m \
  -e MAX_SPEND=0 -e MAX_CONSECUTIVE_ABANDONS="$ABANDONS" -e RETRY_ABANDONED=1 \
  -e CARRY_FINDINGS=1 \
  -v "$H/ArchUnitGo:/work/repo" \
  -v "$H/logs:/work/logs" \
  archunitdev >> "$H/logs/loop.out" 2>&1
rc=$?
say "the run has exited (rc=$rc)"

# No `set -e`: the commits exist only on this volume and have to leave it whatever the exit status was.
sudo -u ec2-user git -C "$H/ArchUnitGo" bundle create "$H/logs/work-$HOST-refix.bundle" --all \
  && say "bundled $(sudo -u ec2-user git -C "$H/ArchUnitGo" rev-list --count origin/main..main) unpushed commit(s)"
aws s3 cp "$H/logs/work-$HOST-refix.bundle" "$BUCKET/handoff/work-$HOST-refix.bundle" --region "$REGION" \
  && say "bundle uploaded"

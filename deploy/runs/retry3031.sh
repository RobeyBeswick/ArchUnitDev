#!/bin/bash
#
# #30 and #31 again, on a host of their own, with the runway the main batch could not give them.
#
# Neither failure was a defect in the loop. Both implementers hit the 45m TIMEOUT and were cut off
# mid-change (rc=124, ~$17 each), which sent an oversized partial diff to the gate and spent a whole
# round before any critic saw the work — so they got three fix cycles where the batch was configured
# for four. #31 was then converging on the test critic's findings, 3 -> 2 -> 1 -> 1, and simply ran
# out of rounds; #30 was flat at 2. The critics were finding real mutation-survival holes each round,
# not looping on the same one.
#
# Hence: 10 fixes and an 11th round that gates and judges without fixing, 120m per step, and no cap on
# spend or issue count. The instruction was that cost is not the constraint and a working result is.
#
# MAX_CONSECUTIVE_ABANDONS=0 turns off the "the environment is broken" tripwire. That is right here and
# wrong in general: the entire queue is two issues that have already been abandoned once, so the
# tripwire would fire on the very outcome this host exists to retry.
#
# CARRY_FINDINGS=1 is what makes the first attempts' reviews count for something. The verdicts are
# already in the log directory; without the flag a first attempt ignores them and pays again to
# re-derive what is sitting on disk.
#
# Run as root:  sudo /home/ec2-user/retry3031.sh
#
set -uo pipefail

BUCKET=s3://<log-bucket>
REGION=us-east-1
H=/home/ec2-user

say() { printf '%s  retry3031: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# The same refusals as the main batch. A second loop against the same working tree, or a tree with
# uncommitted work in it, is how you lose commits that exist in one place.
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
# CARRY_FINDINGS failing open is the quiet failure this guards: run.sh narrates the carry when it finds
# verdicts and says nothing at all when it does not, so a provisioning slip reads as a normal run.
for n in 30 31; do
  ls "$H"/logs/$n-*.verdict.json > /dev/null 2>&1 \
    || { say "REFUSING: no verdicts for #$n in $H/logs — CARRY_FINDINGS would carry nothing, silently"; exit 1; }
done
if ! grep -q 'CARRY_FINDINGS' "$H/ArchUnitDev/run.sh"; then
  say "REFUSING: the built harness has no CARRY_FINDINGS — wrong branch or a stale image"
  exit 1
fi

export GH_TOKEN="$(aws secretsmanager get-secret-value --region "$REGION" \
  --secret-id archunitdev/gh-token --query SecretString --output text)"
[ -n "$GH_TOKEN" ] || { say "REFUSING: the GitHub token came back empty"; exit 1; }

say "starting #30 and #31: MAX_ROUNDS=10 TIMEOUT=120m no spend cap, CARRY_FINDINGS=1"
sudo -u ec2-user --preserve-env=GH_TOKEN docker run --rm \
  -e GH_TOKEN -e NO_PUSH=1 -e RETRO=1 \
  -e MAX_ISSUES=0 -e MAX_ROUNDS=10 -e TIMEOUT=120m \
  -e MAX_SPEND=0 -e MAX_CONSECUTIVE_ABANDONS=0 -e RETRY_ABANDONED=1 \
  -e CARRY_FINDINGS=1 \
  -v "$H/ArchUnitGo:/work/repo" \
  -v "$H/logs:/work/logs" \
  archunitdev >> "$H/logs/loop.out" 2>&1
rc=$?
say "the retry has exited (rc=$rc)"

# No `set -e` above this line on purpose: the commits are the point, they exist only on this volume,
# and they have to be got off it whatever the loop's exit status was. Into handoff/, which is the one
# prefix this role can both write and read — the main batch's equivalent line targets a prefix it has
# no permission for and fails there.
sudo -u ec2-user git -C "$H/ArchUnitGo" bundle create "$H/logs/retry-work.bundle" --all \
  && say "bundled $(sudo -u ec2-user git -C "$H/ArchUnitGo" rev-list --count origin/main..main) unpushed commit(s)"
aws s3 cp "$H/logs/retry-work.bundle" "$BUCKET/handoff/retry-30-31-work.bundle" --region "$REGION" \
  && say "bundle uploaded"

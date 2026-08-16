#!/bin/bash
#
# Re-prepare the loop host after it has been stopped and resized: the harness at the branch with the
# new limits, a rebuilt image, and log shipping under a fresh prefix.
#
# This host already holds everything else. Its volume survived the resize (delete_on_termination is
# false and a stop/start does not touch the root device anyway), so the target repo is still there with
# #11-#34 committed on local main, and so are the logs — which is the whole reason to resize this host
# rather than hand its queue to a clean one.
#
# Run as root, after the resize:  sudo /home/ec2-user/provision-b.sh
#
set -uo pipefail

BUCKET=s3://<log-bucket>
REGION=us-east-1
H=/home/ec2-user
# A new prefix, not a resume of the first batch's. The two runs share this log directory and will write
# the same filenames for any issue both touch (#34, if it abandoned), so a fresh prefix is what keeps
# the first attempt's evidence readable instead of overwritten in place.
NEW_RUN_ID=20260815-b-35-44

say() { printf '%s  provision-b: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
die() { say "FAILED: $*"; exit 1; }
ec2() { sudo -u ec2-user "$@"; }

# Refuse if the batch somehow survived. Rebuilding the image under a running loop would leave the
# container on the old code and the next launch on the new, which is the kind of mismatch that is only
# ever diagnosed hours later.
if docker ps --format '{{.Command}}' | grep -q 'run\.sh'; then
  die "a loop is still running — the stopper has not done its job, do not rebuild under it"
fi

say "memory now: $(free -g | awk '/^Mem:/ {print $2}')GiB, $(nproc) vCPU"

# --- the harness, at the branch with the new limits ------------------------------------------------
say "fetching the harness bundle"
aws s3 cp "$BUCKET/handoff/harness.bundle" "$H/harness.bundle" --region "$REGION" --only-show-errors \
  || die "could not fetch the harness bundle"
chown ec2-user:ec2-user "$H/harness.bundle"
ec2 git -C "$H/ArchUnitDev" fetch "$H/harness.bundle" '+refs/heads/*:refs/remotes/handoff/*' \
  || die "could not fetch from the harness bundle"
ec2 git -C "$H/ArchUnitDev" checkout -B retry-35-44 handoff/worktree-retry-host-30-31 \
  || die "could not check out the harness branch"
say "harness at $(ec2 git -C "$H/ArchUnitDev" log --oneline -1)"

# --- the tree this host already built --------------------------------------------------------------
[ -z "$(ec2 git -C "$H/ArchUnitGo" status --porcelain)" ] \
  || die "the target repo is dirty — the batch did not exit cleanly, look before rebuilding over it"
ec2 git -C "$H/ArchUnitGo" rev-parse --abbrev-ref HEAD | grep -qx main \
  || die "the target repo is not on main"
say "target repo on main at $(ec2 git -C "$H/ArchUnitGo" rev-parse --short HEAD), $(ec2 git -C "$H/ArchUnitGo" rev-list --count origin/main..main) unpushed commit(s)"

# --- the image --------------------------------------------------------------------------------------
say "rebuilding the image (several minutes)"
docker build -t archunitdev "$H/ArchUnitDev" > "$H/build3.log" 2>&1 \
  || { tail -30 "$H/build3.log"; die "docker build — full output in $H/build3.log"; }
say "image rebuilt"

# --- log shipping -----------------------------------------------------------------------------------
# The old log-sync died with the instance stop; nothing has been copied since. The first sync here is
# also the flush of whatever the batch wrote in its last five minutes.
say "starting log-sync under $NEW_RUN_ID"
S3_LOGS="$BUCKET/loop" RUN_ID="$NEW_RUN_ID" LOGS="$H/logs" \
  setsid nohup "$H/ArchUnitDev/deploy/log-sync.sh" > "$H/log-sync-b.out" 2>&1 &
sleep 30
grep -q 'first sync done' "$H/log-sync-b.out" \
  || { cat "$H/log-sync-b.out"; die "log-sync could not get its first sync away"; }
say "log-sync running -> $BUCKET/loop/$NEW_RUN_ID"

say "ready. Launch with: sudo $H/batch35.sh"

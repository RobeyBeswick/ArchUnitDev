#!/usr/bin/env bash
#
# Copies the loop's logs to S3 while it runs. Host-side, alongside the container — not part of the
# loop, which needs no S3 to work.
#
# It syncs on a timer rather than at the end because the failure it exists for is the instance dying
# mid-run: an end-of-run copy is exactly the case that never executes. The logs are the only record
# of *why* a critic blocked something — GitHub keeps the outcome, the diffs and verdicts are here —
# and they live on a root EBS volume that terminates with the instance.
#
# Usage:
#   S3_LOGS=s3://my-bucket/loop LOGS=/home/ec2-user/logs deploy/log-sync.sh
#
set -uo pipefail

LOGS="${LOGS:-/home/ec2-user/logs}"
S3_LOGS="${S3_LOGS:-}"
SYNC_EVERY="${SYNC_EVERY:-300}"
# One prefix per run of this script, so a re-run of an issue cannot silently overwrite the artifacts
# that explain what happened the first time. Set it yourself to resume into an existing prefix after
# a restart. (The alternative is a flat prefix with bucket versioning; see deploy/README.md.)
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"

say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { say "log-sync: $*" >&2; exit 1; }

[ -n "$S3_LOGS" ] || die "set S3_LOGS to a destination, e.g. S3_LOGS=s3://archunitdev-logs/loop"
[ -d "$LOGS" ]    || die "LOGS=$LOGS is not a directory — the loop writes its logs there, so it must exist first"
command -v aws >/dev/null || die "the aws CLI is not on PATH"

DEST="${S3_LOGS%/}/$RUN_ID"

sync_once() {
  aws s3 sync "$LOGS" "$DEST" --only-show-errors
}

# A final sync on the way out, so stopping the run flushes the last few minutes rather than losing
# them. `sleep` runs as a background child and is waited on: bash defers a trap until the foreground
# child exits, so a plain `sleep 300` would swallow the signal for up to five minutes.
finish() {
  say "log-sync: signal received — final sync to $DEST"
  sync_once || say "log-sync: WARNING the final sync failed; the logs are still on this volume"
  exit 0
}
trap finish TERM INT

# The first sync is fatal on failure. A missing bucket, a prefix the instance role cannot write or a
# region mismatch are all configuration mistakes, and the whole point is to find them at the start of
# the night instead of discovering at 04:00 that nothing was ever copied.
say "log-sync: $LOGS -> $DEST every ${SYNC_EVERY}s"
sync_once || die "the first sync failed — fix the destination or the instance role before relying on this. Nothing has been copied."
say "log-sync: first sync done"

# Afterwards a failure is a warning, not the end: a transient S3 error or a brief network wobble must
# not stop the copies for the rest of the run. The successful-sync timestamp is narrated so a
# permanently broken sync reads as staleness in this log rather than as silence.
while :; do
  sleep "$SYNC_EVERY" & wait $!
  if sync_once; then
    say "log-sync: synced"
  else
    say "log-sync: WARNING sync failed, retrying in ${SYNC_EVERY}s"
  fi
done

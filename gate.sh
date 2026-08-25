#!/usr/bin/env bash
# Dispatch to the per-language gate. TARGET_LANG selects which stack the target repo is, and with it
# the script that holds that stack's deterministic checks: gate/$TARGET_LANG.sh. Defaults to go, so
# a manual `./gate.sh` and a host that has not been told otherwise behave exactly as they did when
# the Go gate was the only gate.
#
# Each gate script keeps the whole picture in one file — the build, the test, the lint, the
# reward-hacking guards, and the network-failure handling that must never fail the gate — on the
# principle that two self-contained scripts are easier to keep honest than one script with a
# language switch threaded through it.
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_LANG="${TARGET_LANG:-go}"

[ -f "$HARNESS/gate/$TARGET_LANG.sh" ] || {
  echo "gate: no gate script for TARGET_LANG=$TARGET_LANG (looked for $HARNESS/gate/$TARGET_LANG.sh)" >&2
  exit 1
}
exec "$HARNESS/gate/$TARGET_LANG.sh" "$@"
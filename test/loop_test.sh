#!/usr/bin/env bash
#
# Exercises run.sh's round loop end to end with stubbed `claude` and `gh`. No model, no network,
# no spend, a couple of seconds.
#
# The point of this file is the paths a real run almost never takes and therefore never validates:
# a critic returning FAIL and the findings reaching the fixer, a critic returning garbage, and an
# issue being abandoned after MAX_ROUNDS. Two clean rounds against a real repo prove none of that.
#
# Usage: test/loop_test.sh [scenario ...]      (default: all)
#
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$HARNESS/test/stub"
KEEP="${KEEP:-}"          # KEEP=1 leaves the temp directories behind for inspection

passed=0
failed=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$1"; passed=$((passed + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failed=$((failed + 1)); }
want() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# want_grep <pattern> <file> <description>
want_grep() {
  if grep -qF "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3 (no '$1' in $(basename "$2"))"; fi
}
want_no_grep() {
  if grep -qF "$1" "$2" 2>/dev/null; then bad "$3 (unexpected '$1' in $(basename "$2"))"; else ok "$3"; fi
}

# --- fixture -----------------------------------------------------------------------

setup() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/archunitdev-loop-test.XXXXXX")
  REPO="$ROOT/repo"; LOGS="$ROOT/logs"; STUB_DIR="$ROOT/stub"
  mkdir -p "$REPO" "$LOGS" "$STUB_DIR"

  git init -q --bare "$ROOT/origin.git"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email dev@example.invalid
  git -C "$REPO" config user.name  "Stub Dev"
  git -C "$REPO" config commit.gpgsign false
  printf 'a stub target repository\n' > "$REPO/README.md"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m "initial"
  git -C "$REPO" remote add origin "$ROOT/origin.git"
  git -C "$REPO" push -q origin main
  BASE=$(git -C "$REPO" rev-parse HEAD)

  # One open issue. The repo has no go.mod, so gate.sh skips the Go toolchain and runs only the
  # reward-hacking guards: this test is about the harness, not about golangci-lint.
  printf '2\n' > "$STUB_DIR/open-issues"
}

teardown() {
  [ -n "$KEEP" ] && { printf '  kept %s\n' "$ROOT"; return; }
  rm -rf "$ROOT"
}

# run_loop <scenario> [VAR=VAL ...]  -> exit status in RC, output in $ROOT/run.out
run_loop() {
  local scenario="$1"; shift
  PATH="$STUBS:$PATH" \
  env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_SESSION_TOKEN \
      ANTHROPIC_API_KEY=stub-key-not-used \
      SCENARIO="$scenario" STUB_DIR="$STUB_DIR" REPO="$REPO" LOGS="$LOGS" \
      "$@" \
      "$HARNESS/run.sh" > "$ROOT/run.out" 2>&1
  RC=$?
}

in_head()  { git -C "$REPO" show "HEAD:$1" 2>/dev/null; }
commits()  { git -C "$REPO" rev-list --count HEAD; }

# contains <needle> <haystack> — substring test without a pipe. `git ... | grep -q` is wrong here:
# grep -q exits on the first match, git takes SIGPIPE, and with pipefail the pipeline reports 141.
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# --- scenarios ---------------------------------------------------------------------

# Both critics pass on the first round: the ordinary path, and the only one a real run has taken.
scenario_happy() {
  setup
  run_loop happy MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "round 1: gate clean"      "$ROOT/run.out" "the gate ran and passed"
  want_grep "round 1: both critics PASS" "$ROOT/run.out" "both critics passed"
  want_grep "#2 DONE"                  "$ROOT/run.out" "issue landed"
  want_no_grep "fix-"                   "$STUB_DIR/calls" "no fixer was invoked"
  [ "$(commits)" = 2 ]; want $? "exactly one commit was made"
  contains "Closes #2" "$(git -C "$REPO" log -1 --format=%B)"
  want $? "the commit message closes the issue"
  want_grep "2" "$STUB_DIR/closed" "the issue was closed on GitHub"
  contains "Stub issue 2" "$(git -C "$ROOT/origin.git" log --format=%s main)"
  want $? "the commit was pushed to origin"
  [ -f "$REPO/cover.out" ] && bad "cover.out was left in the repo" || ok "no coverage profile left in the repo"
}

# A critic returns FAIL. The findings must reach the fixer, and round 2 must re-review and land.
# This is the path the whole review half of the harness exists for.
scenario_fixround() {
  setup
  run_loop fixround MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "round 1: review=FAIL idiom=PASS" "$ROOT/run.out" "the FAIL verdict was read correctly"
  want_grep "sending findings back"            "$ROOT/run.out" "findings were routed to the fixer"
  want_grep "2-fix-1"                          "$STUB_DIR/calls" "the fixer was invoked"
  want_grep "feature.txt is asserted by no test." "$STUB_DIR/2-fix-1.stdin" \
            "the finding's problem text reached the fix prompt"
  want_grep "FIX: Add a test that fails if feature.txt is empty." "$STUB_DIR/2-fix-1.stdin" \
            "the finding's fix text reached the fix prompt"
  want_grep "Do not start new work."           "$STUB_DIR/2-fix-1.stdin" "fix.md was included"
  want_grep "round 2: both critics PASS"       "$ROOT/run.out" "round 2 re-reviewed and passed"
  want_grep "#2 DONE"                          "$ROOT/run.out" "issue landed after the fix round"
  contains FIXROUND-ACK "$(in_head NOTES.md)"
  want $? "the fix is in the committed tree"
  [ "$(commits)" = 2 ]; want $? "the fix round did not produce a second commit"
}

# A critic produces no parseable verdict. Fail closed: never a silent PASS.
scenario_garbage() {
  setup
  run_loop garbage MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "no structured output — failing closed" "$ROOT/run.out" "the unparseable verdict failed closed"
  want_grep "did not return a verdict" "$STUB_DIR/2-fix-1.stdin" \
            "the synthesised finding reached the fixer"
  want_grep "round 2: both critics PASS" "$ROOT/run.out" "round 2 recovered"
  want_grep "#2 DONE" "$ROOT/run.out" "issue landed"
}

# A critic never passes. The work must be parked on a branch, the repo reset, the issue annotated
# and skipped — and the run must carry on rather than deadlock.
scenario_abandon() {
  setup
  run_loop always_fail

  want "$RC" "exits 0"
  want_grep "ABANDONED after 3 rounds" "$ROOT/run.out" "the issue was abandoned"
  for r in 1 2 3; do
    want_grep "2-fix-$r" "$STUB_DIR/calls" "fix round $r ran"
  done
  [ "$(grep -c '2-fix-' "$STUB_DIR/calls")" = 3 ]; want $? "exactly MAX_ROUNDS fix rounds ran"

  git -C "$REPO" rev-parse --verify --quiet abandoned/issue-2 >/dev/null
  want $? "the work is parked on abandoned/issue-2"
  git -C "$ROOT/origin.git" rev-parse --verify --quiet abandoned/issue-2 >/dev/null
  want $? "the parked branch was pushed"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ]; want $? "the repo was reset to the base commit"
  [ -f "$REPO/feature.txt" ] && bad "the abandoned work is still in the working tree" \
                             || ok "the working tree is clean of the abandoned work"
  git -C "$REPO" show "abandoned/issue-2:feature.txt" >/dev/null 2>&1
  want $? "the abandoned work survives on the branch"

  want_grep "2" "$LOGS/skipped" "the issue was added to the skip list"
  want_grep "needs-human" "$STUB_DIR/edited" "the issue was labelled for a human"
  [ -f "$STUB_DIR/closed" ] && bad "an abandoned issue was closed" || ok "the issue was left open"
  want_grep "no open issues left" "$ROOT/run.out" "the run moved on instead of retrying forever"
  want_grep "0 issue(s) landed, 1 abandoned" "$ROOT/run.out" "the summary is accurate"
}

# NO_PUSH must commit locally and touch nothing remote.
scenario_no_push() {
  setup
  run_loop happy MAX_ISSUES=1 NO_PUSH=1

  want "$RC" "exits 0"
  want_grep "NO_PUSH set, not pushing" "$ROOT/run.out" "the push was skipped"
  want_grep "leaving the issue open"   "$ROOT/run.out" "the issue was left open"
  [ "$(commits)" = 2 ]; want $? "the commit was still made locally"
  [ -f "$STUB_DIR/closed" ] && bad "an issue was closed despite NO_PUSH" || ok "no issue was closed"
  [ "$(git -C "$ROOT/origin.git" rev-list --count main)" = 1 ]; want $? "origin was not advanced"
}

# The two silent-defeat guards in preflight: a Go repo whose lint enforcement is not actually there.
# A green gate that checks less than it claims is the worst outcome an overnight run can have, so
# both of these must be fatal before any work starts, not warnings.
scenario_preflight() {
  setup
  printf 'module example.invalid/x\n\ngo 1.24\n' > "$REPO/go.mod"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "add go.mod"

  run_loop happy PREFLIGHT_ONLY=1
  [ "$RC" -ne 0 ]; want $? "a Go repo with no .golangci.yml is rejected"
  want_grep "no .golangci.yml" "$ROOT/run.out" "and says why"

  printf 'version: "2"\n' > "$REPO/.golangci.yml"
  run_loop happy PREFLIGHT_ONLY=1 LINT=golangci-lint-that-does-not-exist
  [ "$RC" -ne 0 ]; want $? "a missing linter binary is rejected"
  want_grep "is not installed" "$ROOT/run.out" "and says why"

  run_loop happy PREFLIGHT_ONLY=1 LINT=golangci-lint-that-does-not-exist ALLOW_NO_LINT=1
  want "$RC" "ALLOW_NO_LINT=1 overrides both checks"
  want_grep "everything checks out" "$ROOT/run.out" "and preflight otherwise passes"
}

# --- driver -----------------------------------------------------------------------

ALL="happy fixround garbage abandon no_push preflight"
for s in ${*:-$ALL}; do
  printf '\n=== %s\n' "$s"
  if ! declare -F "scenario_$s" >/dev/null; then
    bad "no such scenario: $s"; continue
  fi
  "scenario_$s"
  teardown
done

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

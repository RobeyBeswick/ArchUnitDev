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

  # Where run.sh is invoked from. It only matters for a relative LOGS, but it has to be reset per
  # scenario or one scenario's cwd leaks into the next.
  RUN_CWD=""
}

teardown() {
  [ -n "$KEEP" ] && { printf '  kept %s\n' "$ROOT"; return; }
  rm -rf "$ROOT"
}

# run_loop <scenario> [VAR=VAL ...]  -> exit status in RC, output in $ROOT/run.out
run_loop() {
  local scenario="$1"; shift
  ( cd "${RUN_CWD:-.}" || exit 1
    PATH="$STUBS:$PATH" \
    env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_SESSION_TOKEN \
        ANTHROPIC_API_KEY=stub-key-not-used \
        SCENARIO="$scenario" STUB_DIR="$STUB_DIR" REPO="$REPO" LOGS="$LOGS" \
        SKIP_MODULE_CHECK=1 \
        "$@" \
        "$HARNESS/run.sh" ) > "$ROOT/run.out" 2>&1
  RC=$?
}

# run_retro [VAR=VAL ...] -- [issue ...]  -> exit status in RC, output in $ROOT/retro.out
# The `--` is not decoration: retro.sh takes issue numbers as arguments and its knobs as environment,
# so a single flat list would be ambiguous the first time an issue number looked like an assignment.
run_retro() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  ( cd "${RUN_CWD:-.}" || exit 1
    PATH="$STUBS:$PATH" \
    env -u CLAUDE_CODE_USE_BEDROCK -u AWS_PROFILE -u AWS_SESSION_TOKEN \
        ANTHROPIC_API_KEY=stub-key-not-used \
        SCENARIO=happy STUB_DIR="$STUB_DIR" REPO="$REPO" LOGS="$LOGS" \
        ${envs[@]+"${envs[@]}"} \
        "$HARNESS/retro.sh" "$@" ) > "$ROOT/retro.out" 2>&1
  RC=$?
}

# run_gate <base-rev>  -> exit status in RC, output in $ROOT/gate.out
# gate.sh directly, with no loop around it: the fixture repo has no go.mod, so the Go toolchain steps
# skip themselves and what runs is the reward-hacking guards, which is what these scenarios are about.
run_gate() {
  ( cd "$REPO" && env REPO="$REPO" BASE="$1" bash "$HARNESS/gate.sh" ) > "$ROOT/gate.out" 2>&1
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
  want_grep "round 1: all 3 critics PASS" "$ROOT/run.out" "all three critics passed"
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
  want_grep "round 2: all 3 critics PASS"      "$ROOT/run.out" "round 2 re-reviewed and passed"
  want_grep "#2 DONE"                          "$ROOT/run.out" "issue landed after the fix round"
  contains FIXROUND-ACK "$(in_head NOTES.md)"
  want $? "the fix is in the committed tree"
  [ "$(commits)" = 2 ]; want $? "the fix round did not produce a second commit"
}

# Only the test critic objects. Its findings must reach the fixer, and the two critics that passed
# must contribute no section at all — an empty heading reads as a reviewer with nothing to say.
scenario_testcritic() {
  setup
  run_loop testcritic MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "round 1: review=PASS idiom=PASS tests=FAIL" "$ROOT/run.out" "the third critic's verdict was read"
  want_grep "2-tests-1" "$STUB_DIR/calls" "the test critic was invoked"
  want_grep "Blocking findings — test critic" "$STUB_DIR/2-fix-1.stdin" "its findings are attributed to it"
  want_grep "Nothing asserts that feature.txt is non-empty." "$STUB_DIR/2-fix-1.stdin" \
            "the test critic's finding reached the fix prompt"
  contains "Blocking findings — correctness reviewer" "$(cat "$STUB_DIR/2-fix-1.stdin")"
  [ $? -ne 0 ]; want $? "the passing critics contributed no empty section"
  want_grep "round 2: all 3 critics PASS" "$ROOT/run.out" "round 2 passed unanimously"
  want_grep "#2 DONE" "$ROOT/run.out" "issue landed after the fix round"
}

# A critic produces no parseable verdict. Fail closed: never a silent PASS.
scenario_garbage() {
  setup
  run_loop garbage MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "no structured output — failing closed" "$ROOT/run.out" "the unparseable verdict failed closed"
  want_grep "did not return a verdict" "$STUB_DIR/2-fix-1.stdin" \
            "the synthesised finding reached the fixer"
  want_grep "round 2: all 3 critics PASS" "$ROOT/run.out" "round 2 recovered"
  want_grep "#2 DONE" "$ROOT/run.out" "issue landed"
}

# A critic never passes. The work must be parked on a branch, the repo reset, the issue annotated
# and skipped — and the run must carry on rather than deadlock.
scenario_abandon() {
  setup
  run_loop always_fail

  want "$RC" "exits 0"
  want_grep "ABANDONED — no unanimous PASS after 3 round(s) of fixes, the last of them reviewed" \
            "$ROOT/run.out" "the issue was abandoned, and the reason given is the one that applies"
  for r in 1 2 3; do
    want_grep "2-fix-$r" "$STUB_DIR/calls" "fix round $r ran"
  done
  [ "$(grep -c '2-fix-' "$STUB_DIR/calls")" = 3 ]; want $? "exactly MAX_ROUNDS fix rounds ran"

  # MAX_ROUNDS bounds the fixes, and one more round judges the last of them. Without that round the
  # loop's final act is a fix nobody gates or reviews: paid for, then parked on a branch as though it
  # had never happened. That is how the first long batch lost both of its abandoned issues.
  for r in 1 2 3 4; do
    want_grep "2-tests-$r" "$STUB_DIR/calls" "critics voted in round $r"
  done
  want_no_grep "2-fix-4" "$STUB_DIR/calls" "no fixer ran after the final verdict"
  case "$(tail -1 "$STUB_DIR/calls")" in
    2-review-4|2-idiom-4|2-tests-4) ok "the issue's last invocation was a critic, not a fixer" ;;
    *) bad "the issue's last invocation was a critic, not a fixer (got $(tail -1 "$STUB_DIR/calls"))" ;;
  esac
  contains "Final round: review=FAIL" "$(git -C "$REPO" log -1 --format=%B abandoned/issue-2)"
  want $? "the parked branch records the verdict its tip was judged on"

  git -C "$REPO" rev-parse --verify --quiet abandoned/issue-2 >/dev/null
  want $? "the work is parked on abandoned/issue-2"
  git -C "$ROOT/origin.git" rev-parse --verify --quiet abandoned/issue-2 >/dev/null
  want $? "the parked branch was pushed"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE" ]; want $? "the repo was reset to the base commit"
  [ -f "$REPO/feature-2.txt" ] && bad "the abandoned work is still in the working tree" \
                               || ok "the working tree is clean of the abandoned work"
  git -C "$REPO" show "abandoned/issue-2:feature-2.txt" >/dev/null 2>&1
  want $? "the abandoned work survives on the branch"

  want_grep "2" "$LOGS/skipped" "the issue was added to the skip list"
  want_grep "needs-human" "$STUB_DIR/edited" "the issue was labelled for a human"
  [ -f "$STUB_DIR/closed" ] && bad "an abandoned issue was closed" || ok "the issue was left open"
  want_grep "no open issues left" "$ROOT/run.out" "the run moved on instead of retrying forever"
  want_grep "0 issue(s) landed, 1 abandoned" "$ROOT/run.out" "the summary is accurate"

  # Nothing landed after this issue, so a re-attempt would run the same prompts over the same tree and
  # fail the same way for the same reason. This is the case that keeps the retry phase from doubling
  # the cost of a batch where everything abandons — which is what a broken environment looks like.
  want_grep "leaving #2 alone — nothing landed after it" "$ROOT/run.out" \
            "the retry phase declined to re-attempt it on an unchanged base"
  want_no_grep "2-retry-implement" "$STUB_DIR/calls" "so no second attempt was paid for"
}

# The implementer returns having changed nothing. It is the likeliest way an issue in a dependency-
# ordered backlog fails: the work was already done by an earlier issue, and the implementer says so
# instead of inventing something. Everything downstream of the diff has to notice, because a critic
# reviewing an empty diff has nothing to review and would pass it — and a PASS with no commit behind
# it must never close an issue.
scenario_nodiff() {
  setup
  run_loop nodiff MAX_ISSUES=1

  want "$RC" "exits 0"
  want_grep "round 1: gate clean" "$ROOT/run.out" "the gate still ran"
  want_grep "round 1: empty diff — the implementer changed nothing" "$ROOT/run.out" \
            "the empty diff was noticed"
  # The account a human reads in the morning. "ABANDONED after 3 rounds" would send them looking for
  # three verdicts that were never written, instead of at an implementer that touched nothing.
  want_grep "ABANDONED — the implementer changed nothing on round 1" "$ROOT/run.out" \
            "the abandon message gives the actual reason"
  want_no_grep "no unanimous PASS in 3 rounds" "$ROOT/run.out" \
               "and does not claim three review rounds ran"
  want_no_grep "parked on branch" "$ROOT/run.out" "nothing was said to be parked, there being nothing to park"

  # No round 2, and no model spent on a diff that is not there.
  [ "$(grep -c . "$STUB_DIR/calls")" = 1 ]; want $? "the implementer ran once and nothing else ran at all"
  want_no_grep "-fix-" "$STUB_DIR/calls" "no fixer was invoked"
  want_no_grep "-review-" "$STUB_DIR/calls" "no critic was invoked"
  [ -z "$(ls "$LOGS"/*.verdict.json 2>/dev/null)" ]; want $? "no verdict was recorded"

  # And the issue is left exactly as it was found.
  [ "$(commits)" = 1 ]; want $? "no commit was made"
  git -C "$REPO" rev-parse --verify --quiet abandoned/issue-2 >/dev/null
  [ $? -ne 0 ]; want $? "no empty branch was parked"
  [ -f "$STUB_DIR/closed" ] && bad "an issue with no work behind it was closed" || ok "the issue was left open"
  want_grep "2" "$LOGS/skipped" "the issue was skipped so the queue moves on"
  want_grep "needs-human" "$STUB_DIR/edited" "and flagged for a human, who is the only one who can say why"
  want_grep "0 issue(s) landed, 1 abandoned" "$ROOT/run.out" "the summary is accurate"
}

# NO_PUSH must commit locally and touch nothing remote.
scenario_no_push() {
  setup
  run_loop happy MAX_ISSUES=1 NO_PUSH=1

  want "$RC" "exits 0"
  want_grep "NO_PUSH set, so not pushing" "$ROOT/run.out" "the push was skipped"
  want_grep "leaving the issue open"   "$ROOT/run.out" "the issue was left open"
  [ "$(commits)" = 2 ]; want $? "the commit was still made locally"
  [ -f "$STUB_DIR/closed" ] && bad "an issue was closed despite NO_PUSH" || ok "no issue was closed"
  [ "$(git -C "$ROOT/origin.git" rev-list --count main)" = 1 ]; want $? "origin was not advanced"
}

# Two issues in one run. Everything about the queue that a one-issue run cannot show: that it
# advances, that the second issue's base is the first issue's commit rather than the original HEAD,
# and that each issue is implemented exactly once.
#
# Under NO_PUSH specifically, because that is where advancing is not free: an issue normally leaves
# the queue by being closed, and NO_PUSH does not close it, so without the landed list the loop
# re-serves the issue it just finished.
scenario_two_issues() {
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  run_loop happy MAX_ISSUES=2 NO_PUSH=1

  want "$RC" "exits 0"
  want_grep "=== issue #2" "$ROOT/run.out" "the first issue was picked up"
  want_grep "=== issue #3" "$ROOT/run.out" "the second issue was picked up"
  want_grep "hit MAX_ISSUES=2" "$ROOT/run.out" "the run stopped at the limit rather than looping"
  want_grep "2 issue(s) landed" "$ROOT/run.out" "both issues are counted as landed"
  want_no_grep "empty diff" "$ROOT/run.out" "neither issue was served to the implementer twice"
  want_no_grep "ABANDONED" "$ROOT/run.out" "nothing was abandoned"

  [ "$(grep -c -- '-implement' "$STUB_DIR/calls")" = 2 ]; want $? "exactly one implement per issue"
  [ "$(commits)" = 3 ]; want $? "one commit per issue, on top of each other"
  contains "Closes #3" "$(git -C "$REPO" log -1 --format=%B)"
  want $? "the second commit closes the second issue"
  contains "Closes #2" "$(git -C "$REPO" log -1 --format=%B HEAD~1)"
  want $? "the first commit closes the first issue"

  # The base moved. If it had not, #3's diff would carry #2's file as well as its own, and every
  # critic would spend the run re-reviewing work that was already approved.
  want_grep "feature-3.txt" "$LOGS/3-diff-1.patch" "#3's diff contains its own work"
  want_no_grep "feature-2.txt" "$LOGS/3-diff-1.patch" "#3's diff is against #2's commit, not the run's start"

  want_grep "2" "$LOGS/landed" "the landed list records the first issue"
  want_grep "3" "$LOGS/landed" "the landed list records the second issue"

  # Both issues are still open, so both entries must survive a second run — that is what stops a
  # NO_PUSH run re-implementing them. Only a *closed* issue's entry is pruned.
  run_loop happy MAX_ISSUES=1 NO_PUSH=1
  want_grep "2" "$LOGS/landed" "an entry for a still-open issue survives the next run"
  want_grep "no open issues left" "$ROOT/run.out" "and the queue stays empty rather than re-serving it"

  # ...whereas an issue that is no longer open has an entry that can only do harm: reopening an issue
  # is how a human says the work was not good enough, and a permanent skip would hide it for ever.
  printf '3\n' > "$STUB_DIR/open-issues"
  run_loop happy MAX_ISSUES=0 NO_PUSH=1
  want_grep "pruned issue(s) no longer open: 2" "$ROOT/run.out" "a closed issue's entry is pruned"
  want_no_grep "2" "$LOGS/landed" "and is gone from the file"
  want_grep "3" "$LOGS/landed" "while the still-open issue's entry stays"

  # And the case where EVERY entry goes, which is its own test because the obvious awk for "which
  # entries went" — NR==FNR across two files — reports nothing when the first file is empty. That
  # pruned the file correctly and said nothing, and an empty open-issue list is not exotic: it is the
  # state this loop is working towards.
  : > "$STUB_DIR/open-issues"
  run_loop happy MAX_ISSUES=0 NO_PUSH=1
  want_grep "pruned issue(s) no longer open: 3" "$ROOT/run.out" "the last entry is named when every entry goes"
  [ ! -s "$LOGS/landed" ]; want $? "and the file is left empty"
  [ -f "$STUB_DIR/closed" ] && bad "an issue was closed despite NO_PUSH" || ok "neither issue was closed"
  [ "$(git -C "$ROOT/origin.git" rev-list --count main)" = 1 ]; want $? "origin was not advanced"
}

# A push that fails must not close the issue. This is the one path where the loop could report an
# issue resolved with nothing on origin to show for it, so it stops the run instead.
# The end-of-run count, against a skipped list that is not all this run's fault. LOGS is deliberately
# long-lived, so the list holds every abandonment any earlier batch recorded, and operators put numbers
# there by hand to hold an issue back — both of which the summary used to report as tonight's failures.
#
# Not hypothetical: host B landed all seven of its issues on 15 August 2026 and announced "7 issue(s)
# landed, 5 abandoned", the five being two issues handed to a second host and three held until a merge.
# The retrospective is handed these numbers, and this week already cost two retros that reasoned
# confidently from a figure nobody had checked.
scenario_abandon_count() {
  setup
  # One issue this run will abandon, one held back by hand, and one left over from an earlier batch
  # that no longer appears in the queue at all.
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  printf '3\n99\n' > "$LOGS/skipped"

  run_loop always_fail MAX_CONSECUTIVE_ABANDONS=0

  want_grep "run finished: 0 issue(s) landed, 1 abandoned" "$ROOT/run.out" \
            "only the issue this run abandoned is counted as abandoned"
  want_grep "2 further issue(s)" "$ROOT/run.out" "the rest are reported separately"
  want_grep "held back by hand: 3 99" "$ROOT/run.out" "and named, so an operator can see whose they are"
  want_no_grep "0 issue(s) landed, 3 abandoned" "$ROOT/run.out" \
            "the whole skipped list is not reported as this run's failures"

  # The other direction: nothing extra in the list, so no second line to explain away. A run that
  # abandoned everything it touched must still say so plainly.
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  run_loop always_fail MAX_CONSECUTIVE_ABANDONS=0
  want_grep "run finished: 0 issue(s) landed, 2 abandoned" "$ROOT/run.out" \
            "a run that abandoned both of its issues reports both"
  want_no_grep "further issue(s)" "$ROOT/run.out" "and adds no line about issues that are not there"

  # And a clean run over a polluted list: the count that matters most, because this is the one that
  # reads as a failure when it is a success.
  setup
  printf '2\n' > "$STUB_DIR/open-issues"
  printf '41\n42\n44\n' > "$LOGS/skipped"
  run_loop happy
  want_grep "run finished: 1 issue(s) landed, 0 abandoned" "$ROOT/run.out" \
            "a run that abandoned nothing reports nothing abandoned, however full the list is"
  want_grep "held back by hand: 41 42 44" "$ROOT/run.out" "while still accounting for the held issues"
}

# git does not read GH_TOKEN; gh does. So every `gh` call in run.sh authenticated, the preflight
# `gh auth status` passed, and `git push` could not have worked — it would have asked for a username,
# found no terminal, and died with 128. Nothing caught it because every run so far set NO_PUSH=1, so
# the first batch that actually intended to deliver would have aborted on its first landed issue.
#
# Measured in the real image with a valid token in the environment before this was written:
# `gh auth status` ok, `git credential fill` fatal, `git push --dry-run` rc=128.
#
# Every run_loop here blanks the global and system git config. Without that, a maintainer with
# osxkeychain or a manager-of-record helper configured for github.com would have git answer the
# credential request from their own machine, and the negative case would pass for the wrong reason —
# while quietly consulting their real GitHub credential to do it.
scenario_push_credential() {
  local HERMETIC=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
  setup
  git -C "$REPO" remote set-url origin https://github.com/example/example.git

  run_loop happy PREFLIGHT_ONLY=1 "${HERMETIC[@]}"
  [ "$RC" -ne 0 ]; want $? "a run that intends to push is refused when git has no github.com credential"
  want_grep "git cannot get a credential for github.com" "$ROOT/run.out" "and says what is wrong"
  want_grep "gh reads GH_TOKEN and git does not" "$ROOT/run.out" "and names the distinction it turns on"

  run_loop happy PREFLIGHT_ONLY=1 STUB_GH_CRED=stub-token "${HERMETIC[@]}"
  want "$RC" "a credential helper that answers satisfies the check"
  want_grep "everything checks out" "$ROOT/run.out" "and the rest of preflight still runs"

  run_loop happy PREFLIGHT_ONLY=1 NO_PUSH=1 "${HERMETIC[@]}"
  want "$RC" "a NO_PUSH run needs no push credential"

  # A local remote is not github.com, and the helper is scoped to that host — checking there would
  # fail for a reason it is not equipped to fix. Every other scenario in this file depends on this,
  # which is why it is asserted rather than left as an accident of the fixture.
  setup
  run_loop happy PREFLIGHT_ONLY=1 "${HERMETIC[@]}"
  want "$RC" "a non-github origin skips the check entirely"

  # The check proves a credential is reachable; these prove the pushes actually reach for it. A
  # preflight that passes while the push sites go unchanged is the bug with a green light on it.
  [ "$(grep -acF 'git "${GIT_CRED[@]}" push' "$HARNESS/run.sh")" = 2 ]
  want $? "both push sites pass the credential, not just the preflight"

  # And that none of it is installed anywhere persistent. `git config --global` here would leave a
  # credential helper in the ~/.gitconfig of anyone who ran the loop outside Docker, which the README
  # documents as supported; `store` would write the PAT itself into a file every implementer can read.
  want_no_grep 'config --global credential' "$HARNESS/run.sh" \
            "the helper is not written into anyone's global git config"
  want_no_grep 'credential.helper=store' "$HARNESS/run.sh" \
            "and the token is never persisted to disk by a store helper"
}

scenario_pushfail() {
  setup
  git -C "$REPO" remote set-url origin "$ROOT/there-is-no-remote-here.git"
  run_loop happy MAX_ISSUES=1

  [ "$RC" -ne 0 ]; want $? "the run stops rather than carrying on"
  want_grep "push failed for #2" "$ROOT/run.out" "and says which issue"
  want_grep "the issue stays OPEN" "$ROOT/run.out" "and that the issue was not resolved"

  # Why it failed, in git's words, in the file that gets shipped and read. The day #42 was refused for a
  # missing `workflow` token scope the reason was in the container's stdout and nowhere in run.log, and
  # no wording this message could have chosen would have guessed it.
  want_grep "git said:" "$ROOT/run.out" "and quotes git's own reason"
  want_grep "git said:" "$LOGS/run.log" "including in run.log, not only on stdout"
  [ "$(grep -c 'push failed for #2' "$LOGS/run.log")" = 1 ]
  want $? "as one grep-able line, not a multi-line entry"

  [ -f "$STUB_DIR/closed" ] && bad "the issue was closed with nothing on origin" \
                            || ok "the issue was NOT closed"
  [ "$(commits)" = 2 ]; want $? "the work is still committed locally, so nothing is lost"
  want_no_grep "DONE" "$ROOT/run.out" "the issue was not reported as done"
}

# A token that can reach github.com is not the same as a token allowed to do the job. GitHub refuses any
# push that creates or updates a file under .github/workflows/ unless the token carries the `workflow`
# scope, and it refuses it at the push — #42, the docs site, needs a Pages workflow, and was gated green
# four rounds deep before being rejected at the end of two hours. So it is said at preflight instead.
scenario_workflow_scope() {
  local HERMETIC=(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
  setup
  git -C "$REPO" remote set-url origin https://github.com/example/example.git

  run_loop happy PREFLIGHT_ONLY=1 STUB_GH_CRED=stub-token STUB_GH_SCOPES='gist,repo,workflow' "${HERMETIC[@]}"
  want "$RC" "a token carrying the workflow scope passes preflight"
  want_no_grep "no 'workflow' scope" "$ROOT/run.out" "and is not warned about"
  want_no_grep "reports no OAuth scopes" "$ROOT/run.out" "nor mistaken for one that reports none"

  run_loop happy PREFLIGHT_ONLY=1 STUB_GH_CRED=stub-token STUB_GH_SCOPES='gist,repo,read:org' "${HERMETIC[@]}"
  want "$RC" "a token without it is warned about rather than refused — most issues never touch a workflow"
  want_grep "no 'workflow' scope" "$ROOT/run.out" "and the warning names the scope"
  want_grep "REFUSED at the push" "$ROOT/run.out" "and says where it would go wrong"

  # A fine-grained PAT sends no scope header at all. Absent is unknown, not empty, and saying "no
  # workflow scope" about a token that may well have the permission would train the reader to ignore it.
  run_loop happy PREFLIGHT_ONLY=1 STUB_GH_CRED=stub-token "${HERMETIC[@]}"
  want "$RC" "a token that reports no scopes is not refused either"
  want_grep "reports no OAuth scopes" "$ROOT/run.out" "and is described as unknown rather than missing"
  want_no_grep "no 'workflow' scope" "$ROOT/run.out" "not as definitely lacking the scope"

  run_loop happy PREFLIGHT_ONLY=1 NO_PUSH=1 STUB_GH_SCOPES='gist,repo' "${HERMETIC[@]}"
  want "$RC" "a NO_PUSH run still passes"
  want_no_grep "no 'workflow' scope" "$ROOT/run.out" "and is not warned: it pushes nothing"

  # The header the real API also sends, which the scope reader must not pick up instead.
  want_no_grep "Accepted" "$ROOT/run.out" "X-Accepted-Oauth-Scopes is not mistaken for the scope list"
}

# Consecutive abandonments mean the environment broke, not that every issue is hard. The run must
# stop instead of spending an implement plus MAX_ROUNDS of fixes on each remaining issue.
scenario_breaker() {
  setup
  printf '2\n3\n4\n' > "$STUB_DIR/open-issues"
  run_loop always_fail MAX_CONSECUTIVE_ABANDONS=2

  [ "$RC" -ne 0 ]; want $? "the run stops"
  want_grep "2 issue(s) abandoned in a row" "$ROOT/run.out" "and says why"
  want_grep "2-implement" "$STUB_DIR/calls" "the first issue was attempted"
  want_grep "3-implement" "$STUB_DIR/calls" "the second issue was attempted"
  want_no_grep "4-implement" "$STUB_DIR/calls" "the third issue was never started"
  [ "$(grep -c . "$LOGS/skipped")" = 2 ]; want $? "exactly the two attempted issues are skipped"

  # ...and the escape hatch, for a queue you have decided really is that hard.
  setup
  printf '2\n3\n4\n' > "$STUB_DIR/open-issues"
  run_loop always_fail MAX_CONSECUTIVE_ABANDONS=0
  want "$RC" "MAX_CONSECUTIVE_ABANDONS=0 runs the queue out"
  want_grep "4-implement" "$STUB_DIR/calls" "every issue was attempted"
  want_grep "0 issue(s) landed, 3 abandoned" "$ROOT/run.out" "and the summary is accurate"
}

# The other half of the round bound: an issue whose last fix is the one that satisfies everybody. The
# critics only pass once the third fix has landed, so the round that decides this issue is the verdict
# taken after the final fix. It lands here; under a loop bounded at MAX_ROUNDS *rounds* the same work
# is parked on abandoned/issue-2 with a green gate and every finding addressed, and a human is asked
# to re-derive it. That was 24% of the first long batch's spend.
scenario_late_pass() {
  setup
  run_loop late_pass NO_PUSH=1

  want "$RC" "exits 0"
  want_grep "round 4: all 3 critics PASS" "$ROOT/run.out" "the verdict after the last fix is taken"
  want_grep "#2 DONE" "$ROOT/run.out" "and the issue lands on it"
  want_no_grep "ABANDONED" "$ROOT/run.out" "the work is not abandoned with the critics satisfied"
  want_grep "2-fix-3" "$STUB_DIR/calls" "the third fix ran"
  want_no_grep "2-fix-4" "$STUB_DIR/calls" "and no fourth, MAX_ROUNDS being a bound on fixes"
  [ "$(commits)" = 2 ]; want $? "the work is committed"
  contains "feature-2.txt" "$(in_head feature-2.txt && echo feature-2.txt)"
  want $? "and the implementation is in the commit"
  git -C "$REPO" rev-parse --verify --quiet abandoned/issue-2 >/dev/null \
    && bad "work that passed was also parked as abandoned" \
    || ok "nothing was parked as abandoned"
  want_grep "1 issue(s) landed, 0 abandoned" "$ROOT/run.out" "the summary is accurate"
}

# MAX_ISSUES bounds the issues a run attempts, including the ones it gives up on. An operator sets it
# to scope a batch — "tonight, #14 to #25" — and to cap the spend, and an abandonment is the most
# expensive outcome there is, so it has to count. Gating on landings instead is the kind of bug that
# never shows up in a green run and only surfaces in the one you were watching least.
scenario_bounded() {
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  run_loop fail_one MAX_ISSUES=1

  want "$RC" "the run exits cleanly"
  want_grep "hit MAX_ISSUES=1" "$ROOT/run.out" "the bound was reached"
  want_grep "2-implement" "$STUB_DIR/calls" "the one issue in scope was attempted"
  want_no_grep "3-implement" "$STUB_DIR/calls" "the abandonment did not buy the run a second issue"
  want_grep "0 issue(s) landed, 1 abandoned" "$ROOT/run.out" "the summary is accurate"

  # And a landing counts the same as an abandonment, which is the half that always worked.
  setup
  printf '2\n3\n4\n' > "$STUB_DIR/open-issues"
  run_loop fail_one MAX_ISSUES=2 NO_PUSH=1

  want "$RC" "the run exits cleanly"
  want_grep "3-implement" "$STUB_DIR/calls" "the second issue was attempted"
  want_no_grep "4-implement" "$STUB_DIR/calls" "and the third was not"
  want_grep "1 issue(s) landed, 1 abandoned" "$ROOT/run.out" "one of each, inside a bound of two"
  # The retry phase is exempt from the bound — a re-attempt of #2 is still #2 — and the exemption must
  # not leak into the queue: #4 is out of scope whether or not the retry happens.
  want_grep "2-retry-implement" "$STUB_DIR/calls" "the abandoned issue was re-attempted despite the bound being full"
  want_no_grep "4-implement" "$STUB_DIR/calls" "and the exemption did not admit an issue outside the bound"
}

# One re-attempt of an abandoned issue, at the end, against the tree the batch actually finished on.
#
# The scenario is the real one: the backlog is numbered in dependency order and the loop moves on when
# an issue is abandoned, so #2 fails for want of something #3 provides, #3 lands over it, and the tree
# ends the batch with a hole in the middle of it that nothing points at. Here #2 becomes implementable
# the moment #3's file exists, which is the cheapest faithful model of ArchUnitGo's #21: a Files API
# terminal abandoned while five commits of the kernel it needed landed on top of it.
scenario_retry() {
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  # MAX_ROUNDS=1 keeps it to two rounds an issue; the retry is the subject, not the round loop.
  run_loop retry MAX_ISSUES=2 NO_PUSH=1 MAX_ROUNDS=1

  want "$RC" "the run exits cleanly"
  want_grep "#2 ABANDONED" "$ROOT/run.out" "the issue that needed later work was abandoned first time"
  want_grep "#3 DONE"      "$ROOT/run.out" "the issue after it landed"
  want_grep "hit MAX_ISSUES=2" "$ROOT/run.out" "the main pass ended on its bound"
  want_grep "#2 RE-ATTEMPT" "$ROOT/run.out" "and the abandoned issue was then re-attempted"
  want_grep "landed on the re-attempt" "$ROOT/run.out" "the re-attempt landed, which the first attempt could not"
  want_grep "re-attempted 1 abandoned issue(s)" "$ROOT/run.out" "the summary accounts for the retry"
  want_grep "1 landed" "$ROOT/run.out" "and says how it went"

  # A fresh implementer on a moved base, not a fourth fix round: the retry gets the issue and the tree,
  # and none of the first attempt's *work*.
  want_grep "2-retry-implement" "$STUB_DIR/calls" "the re-attempt ran an implementer of its own"
  contains "Blocking findings" "$(cat "$STUB_DIR/2-retry-implement.stdin")" \
    && bad "the re-attempt was framed as a fix round" \
    || ok "the re-attempt was not framed as a fix round"

  # It does get the findings that were outstanding when the first attempt was parked. They are the
  # paid-for account of why it failed, and leaving them on disk unread is how $40 went on re-deriving
  # work that was already two-thirds approved.
  want_grep "Outstanding findings from an earlier attempt" "$STUB_DIR/2-retry-implement.stdin" \
            "the re-attempt is told an abandoned attempt exists"
  want_grep "This needs what issue 3 provides" "$STUB_DIR/2-retry-implement.stdin" \
            "with the finding that was outstanding when it was parked"
  want_grep "you are not free to reproduce these" "$STUB_DIR/2-retry-implement.stdin" \
            "framed as constraints rather than as a worklist"
  want_grep "carrying 1 outstanding finding(s)" "$ROOT/run.out" "and the carry-over is narrated"
  want_no_grep "Outstanding findings from an earlier attempt" "$STUB_DIR/2-implement.stdin" \
            "while the first attempt of an issue has nothing to carry"

  # Both attempts' evidence survives. A human deciding whether the retry was the right call has only
  # these files to read, and the first attempt's are the half that says why it failed.
  [ -f "$LOGS/2-implement.json" ];       want $? "the first attempt's artifacts are still there"
  [ -f "$LOGS/2-retry-implement.json" ]; want $? "and the re-attempt's are beside them, not on top of them"
  [ -f "$LOGS/2-tests-1.verdict.json" ] && [ -f "$LOGS/2-retry-tests-1.verdict.json" ]
  want $? "each attempt kept its own round-1 verdicts"
  git -C "$REPO" show "abandoned/issue-2:feature-2.txt" >/dev/null 2>&1
  want $? "the first attempt's parked work was not overwritten by the second"

  # Bookkeeping. The skip list is read as a set — by the queue, and by the retrospective to label an
  # outcome — so an issue that has since landed must not still be in it.
  grep -qx 2 "$LOGS/skipped" && bad "the issue that landed is still on the skip list" \
                             || ok "the issue that landed was taken off the skip list"
  want_grep "2" "$LOGS/landed" "and is on the landed list"
  [ "$(commits)" = 3 ]; want $? "one commit for the issue that landed and one for the re-attempt"
  [ "$(grep -c '^2$' "$LOGS/skipped")" = 0 ]; want $? "no duplicate skip entry from the second attempt"

  # And off is off. `${VAR:-1}` would substitute the default for a variable that is *set but empty*,
  # so `RETRY_ABANDONED=` would silently leave the retry on — with the README telling you it is the
  # way to turn it off. The knob has to distinguish unset from empty.
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  run_loop retry MAX_ISSUES=2 NO_PUSH=1 MAX_ROUNDS=1 RETRY_ABANDONED=
  want_grep "#2 ABANDONED" "$ROOT/run.out" "with the retry off the issue is still abandoned"
  want_no_grep "RE-ATTEMPT" "$ROOT/run.out" "and RETRY_ABANDONED= actually switches it off"
  want_no_grep "2-retry-implement" "$STUB_DIR/calls" "so no second attempt is paid for"
  grep -qx 2 "$LOGS/skipped"; want $? "and the issue is left for a human"
}

# MAX_SPEND: the only bound on an unattended run's cost that is denominated in the thing being spent.
# MAX_ISSUES bounds a count, and an issue's cost varies by more than an order of magnitude — 2 rounds
# and $8, or 6 rounds of a hard one and $60 — so a night scoped by issue count has no ceiling anybody
# can state in advance.
#
# The stub charges $0.01 an implement and $0.02 a critic, so a clean issue costs $0.07 and a $0.10 cap
# falls between the first and second boundary. DOUBLE_CRITICS= is pinned throughout rather than left at
# its default: the subject here is the cap, and a scenario whose arithmetic moves when an unrelated
# default changes how many critics run is a scenario that reports the wrong thing when it breaks.
scenario_spend() {
  setup
  printf '2\n3\n4\n' > "$STUB_DIR/open-issues"
  run_loop happy MAX_ISSUES=0 NO_PUSH=1 MAX_SPEND=0.10 DOUBLE_CRITICS=

  want "$RC" "the run exits cleanly rather than dying at the cap"
  want_grep '$0.10 spend cap' "$ROOT/run.out" "the cap is narrated at startup, where an operator can see they set it"
  want_grep "spend so far this run: \$0.07 over 1 issue(s)" "$ROOT/run.out" \
            "each issue boundary reports the running total"
  want_grep "hit MAX_SPEND=\$0.10 (\$0.14 spent over 2 issue(s))" "$ROOT/run.out" \
            "the cap fired at the first boundary past it, and said what it had spent"
  want_grep "=== issue #2" "$ROOT/run.out" "the first issue ran"
  want_grep "=== issue #3" "$ROOT/run.out" "the second issue ran, being under the cap when it started"
  want_no_grep "=== issue #4" "$ROOT/run.out" "and the third was never started"
  want_no_grep "4-implement" "$STUB_DIR/calls" "so nothing was paid for it"

  # The issue that took the run over the cap still landed. A cap that stopped an issue mid-flight would
  # leave an unjudged diff in the tree and no branch to its name, which is the one outcome the whole
  # abandon path exists to prevent — so overshooting by up to one issue is the intended behaviour.
  want_grep "#3 DONE" "$ROOT/run.out" "the issue that crossed the cap was finished, not interrupted"
  [ "$(commits)" = 3 ]; want $? "both issues are committed"
  want_no_grep "ABANDONED" "$ROOT/run.out" "nothing was abandoned by the cap"

  # Per run, not per log directory. LOGS is long-lived and holds every batch ever run into it, so a cap
  # measured over the whole directory would refuse to start the second night after the first spent it.
  run_loop happy MAX_ISSUES=0 NO_PUSH=1 MAX_SPEND=0.10 DOUBLE_CRITICS=
  want_grep "=== issue #4" "$ROOT/run.out" "a fresh run starts at zero even though the log directory is already over the cap"
  want_grep "spend: \$0.07 this run" "$ROOT/run.out" "the final total counts this run"
  want_grep "\$0.21 in logs all told" "$ROOT/run.out" "and reports the log directory's lifetime spend as a separate number"

  # A cap that does not parse must not be treated as one. awk would compare it as a string, and the
  # operator would have a run they believe is capped and is not.
  run_loop happy MAX_ISSUES=1 NO_PUSH=1 MAX_SPEND=lots DOUBLE_CRITICS=
  [ "$RC" = 1 ]; want $? "an unparseable cap is fatal in preflight"
  want_grep "is not a dollar amount" "$ROOT/run.out" "and says so"
}

# DOUBLE_CRITICS: one role, two concurrent passes in round 1, findings unioned.
#
# Three times the test critic has reported one of two findings that were both in front of it, and the
# one it left out cost a full round each time. This is the structural answer, and what it must get
# right is the union — a second pass whose extra finding is dropped on the floor is worse than not
# running it, because it costs the same and reads as thoroughness.
scenario_double_critic() {
  setup
  run_loop union MAX_ISSUES=1 NO_PUSH=1 DOUBLE_CRITICS=tests

  want "$RC" "exits 0"
  want_grep "2-tests-1a" "$STUB_DIR/calls" "the first pass ran"
  want_grep "2-tests-1b" "$STUB_DIR/calls" "and the second"
  want_no_grep "2-review-1a" "$STUB_DIR/calls" "a role not named in DOUBLE_CRITICS runs once"
  want_grep "two passes unioned -> FAIL (2 finding(s) from 1+1)" "$ROOT/run.out" \
            "both findings survive the union, and the merge is narrated"

  # Only the second pass is told to sweep. Two identical prompts are the weakest way to spend twice.
  want_no_grep "For this pass specifically" "$STUB_DIR/2-tests-1a.stdin" "the first pass gets the ordinary prompt"
  want_grep "For this pass specifically" "$STUB_DIR/2-tests-1b.stdin" "the second is told to be exhaustive"
  want_grep "name every instance of a problem you find" "$STUB_DIR/2-tests-1b.stdin" "with the framing that differs from pass one"

  # The point of the union: the fixer is handed both, in one round.
  want_grep "The most important thing." "$STUB_DIR/2-fix-1.stdin" "the fixer got the first pass's finding"
  want_grep "The second thing, which only an exhaustive pass finds." "$STUB_DIR/2-fix-1.stdin" \
            "and the second pass's, in the same round"

  # Downstream reads one verdict file per role per round and must not have to know about this.
  [ -f "$LOGS/2-tests-1.verdict.json" ]; want $? "the canonical verdict path is written"
  [ "$(jq -r '.findings | length' "$LOGS/2-tests-1.verdict.json")" = 2 ]; want $? "and holds both findings"
  [ -f "$LOGS/2-tests-1a.verdict.json" ] && [ -f "$LOGS/2-tests-1b.verdict.json" ]
  want $? "each pass's own verdict is kept as evidence"
  want_grep "round 1: review=PASS idiom=PASS tests=FAIL" "$ROOT/run.out" "the unanimity check reads the merged verdict"
  want_grep "#2 DONE" "$ROOT/run.out" "and the issue lands in round 2"
  [ "$(grep -c -- '-tests-2' "$STUB_DIR/calls")" = 1 ]; want $? "round 2 runs the role once, not twice"

  # Off is off — this doubles the cost of a role, so it has to be switchable in one place.
  setup
  run_loop union MAX_ISSUES=1 NO_PUSH=1 DOUBLE_CRITICS= MAX_ROUNDS=1
  want_no_grep "2-tests-1b" "$STUB_DIR/calls" "DOUBLE_CRITICS= runs every role once"
  want_no_grep "two passes unioned" "$ROOT/run.out" "and nothing is merged"
}

# The gate's kind-pinning guard, which exists because a model found this by hand and charged $5 for it.
#
# Every test in the target repo compares `Kind()` against the constant, which is a tautology: respell
# the constant and the suite stays green, including respelling it onto a collision with a sibling kind.
# Base-relative, because the tree already contains one such constant — landed in #20 with all three
# critics passing it — and a guard that failed on it would blame the next issue's implementer.
scenario_kind_pinning() {
  setup

  # A kind whose literal no test asserts, present at the base commit.
  mkdir -p "$REPO/assertion"
  cat > "$REPO/assertion/kinds.go" <<'GO'
package assertion

const KindOldUnpinned ViolationKind = "old-unpinned"
GO
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "a kind nobody pinned"
  local base; base=$(git -C "$REPO" rev-parse HEAD)

  run_gate "$base"
  want "$RC" "a hole that is already at the base commit does not fail the gate"
  want_grep "unpinned at the base commit too" "$ROOT/gate.out" "and is reported as pre-existing rather than silently ignored"

  # ...whereas adding one is what the guard is for.
  cat >> "$REPO/assertion/kinds.go" <<'GO'

const KindBrandNew ViolationKind = "brand-new"
GO
  run_gate "$base"
  [ "$RC" != 0 ]; want $? "adding an unpinned kind fails the gate"
  want_grep "VIOLATION: the string value of KindBrandNew" "$ROOT/gate.out" "the violation names the constant"
  want_no_grep "KindOldUnpinned is asserted nowhere" "$ROOT/gate.out" "and does not blame the implementer for the pre-existing one"

  # A test comparing Kind() to the constant is the tautology, and must not satisfy the guard.
  cat > "$REPO/assertion/kinds_test.go" <<'GO'
package assertion

func TestKind(t *testing.T) {
  if got := New().Kind(); got != KindBrandNew {
    t.Fatalf("got %v", got)
  }
}
GO
  run_gate "$base"
  [ "$RC" != 0 ]; want $? "comparing Kind() against the constant does not count as pinning it"

  # The literal does.
  cat > "$REPO/assertion/kinds_test.go" <<'GO'
package assertion

func TestKind(t *testing.T) {
  if got := New().Kind(); got != "brand-new" {
    t.Fatalf("got %v", got)
  }
}
GO
  run_gate "$base"
  want "$RC" "a literal assertion in a test satisfies it"

  # Without a base there is nothing to be relative to, and a gate that guessed would either block
  # every manual invocation or check nothing. It reports and passes.
  run_gate ""
  want "$RC" "no BASE means the guard reports rather than fails"
  want_grep "reporting only" "$ROOT/gate.out" "and says which constants it looked at"
}

# The gate's "at least one test exists" check, which on 15 August fired against a tree holding 117
# test files at 100% coverage and abandoned four issues — #31, #35, #36, #37, ten fix rounds each,
# about $80 — because nothing an implementer could write would ever satisfy it.
#
# It was written as `! find . -name '*_test.go' | grep -q .`. `grep -q` exits on its first match and
# closes the pipe; `find` dies of SIGPIPE with 141; `set -o pipefail` reports 141 for the pipeline, and
# `!` turns a successful match into a violation. It is a race the writer has to lose, so it passed for
# months on a small tree and then failed permanently once the repo was big enough for find to still be
# walking when grep left.
#
# Two things are checked here. The behaviour, in both directions, because a guard that cannot fail is
# as bad as one that always does. And the *shape*: `| grep -q` is banned outright in the harness,
# because the bug is invisible at the call site and the next person to write that line will not know.
scenario_test_files_guard() {
  setup

  # A `go` that succeeds at everything, so the go.mod branch of the gate can be reached at all. The
  # fixture deliberately has no go.mod precisely to skip this branch, and this is the one scenario
  # that needs it — the check under test is guarded by `[ -f go.mod ]`.
  cat > "$STUB_DIR/go" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$STUB_DIR/go"
  gate_with_go() {
    ( cd "$REPO" && PATH="$STUB_DIR:$PATH" env REPO="$REPO" BASE="$1" LOGS="$LOGS" \
        bash "$HARNESS/gate.sh" ) > "$ROOT/gate.out" 2>&1
    RC=$?
  }

  printf 'module example.invalid/m\n\ngo 1.23\n' > "$REPO/go.mod"

  # Enough directories that find is still walking when a `grep -q` would leave: the original bug is a
  # race, and one test file in the root would win it and hide the defect.
  local i
  for i in $(seq 1 300); do
    mkdir -p "$REPO/pkg$i"
    printf 'package pkg%s\n' "$i" > "$REPO/pkg$i/a.go"
    printf 'package pkg%s\n\nfunc TestA(t *testing.T) {}\n' "$i" > "$REPO/pkg$i/a_test.go"
  done
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "a module with tests in it"

  gate_with_go "$(git -C "$REPO" rev-parse HEAD)"
  want_no_grep "no test files at all" "$ROOT/gate.out" \
            "a tree full of test files does not report having none"

  # ...and the check still does its job, which is the half that a naive fix would quietly remove.
  find "$REPO" -name '*_test.go' -delete
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "delete every test"
  gate_with_go "$(git -C "$REPO" rev-parse HEAD)"
  [ "$RC" != 0 ]; want $? "a module with no test files at all still fails the gate"
  want_grep "VIOLATION: the module has no test files at all" "$ROOT/gate.out" \
            "and says so"

  # The shape, not just this instance. `cmd | grep -q` under pipefail is wrong in every case where the
  # writer can outlive the match, and both sites that had it were silent failures in opposite
  # directions: this check inverted, and looks_like_network_trouble reporting an outage as a defect.
  # Code lines only — the comments explaining the ban name the banned shape, and a guard that trips on
  # its own rationale teaches the next person to delete the rationale.
  local offenders
  offenders=$(grep -n '| *grep -q' "$HARNESS/gate.sh" "$HARNESS/run.sh" "$HARNESS/retro.sh" 2>/dev/null \
              | grep -vE ':[[:space:]]*#')
  if [ -z "$offenders" ]; then
    ok "no 'cmd | grep -q' pipeline in the harness — pipefail reports the writer's SIGPIPE, not the match"
  else
    bad "a 'cmd | grep -q' pipeline is back: $offenders"
  fi
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

  # Committed, like go.mod above and like the real thing: a lint config left uncommitted now trips
  # the dirty-tree check before the linter checks this scenario is about are reached.
  printf 'version: "2"\n' > "$REPO/.golangci.yml"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "add .golangci.yml"

  run_loop happy PREFLIGHT_ONLY=1 LINT=golangci-lint-that-does-not-exist
  [ "$RC" -ne 0 ]; want $? "a missing linter binary is rejected"
  want_grep "is not installed" "$ROOT/run.out" "and says why"

  run_loop happy PREFLIGHT_ONLY=1 LINT=golangci-lint-that-does-not-exist ALLOW_NO_LINT=1
  want "$RC" "ALLOW_NO_LINT=1 overrides both checks"
  want_grep "everything checks out" "$ROOT/run.out" "and preflight otherwise passes"
}

# The module-resolution probe. This is the one preflight check that must NOT be fatal — most issues
# add no dependency — so the test is as much about it staying a warning as about it firing at all.
scenario_moduleproxy() {
  setup
  if ! command -v go >/dev/null 2>&1; then
    ok "skipped: no go on PATH, so the probe cannot run (it is guarded on the same condition)"
    return
  fi
  printf 'module example.invalid/x\n\ngo 1.24\n' > "$REPO/go.mod"
  printf 'version: "2"\n' > "$REPO/.golangci.yml"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "add go.mod"

  # An unroutable proxy rather than an unresolvable hostname: connection-refused is instant and needs
  # no network at all, where a DNS black hole would make this test take as long as the real failure.
  run_loop happy PREFLIGHT_ONLY=1 SKIP_MODULE_CHECK= GOPROXY=http://127.0.0.1:1
  want "$RC" "an unresolvable module proxy is a warning, not fatal"
  want_grep "cannot resolve module versions" "$ROOT/run.out" "and the warning says what failed"
  want_grep "GOPROXY=direct" "$ROOT/run.out" "and names the fix"
  want_grep "hang until TIMEOUT" "$ROOT/run.out" "and says what it would otherwise cost"
  want_grep "everything checks out" "$ROOT/run.out" "and the rest of preflight still runs"

  run_loop happy PREFLIGHT_ONLY=1 GOPROXY=http://127.0.0.1:1
  want "$RC" "SKIP_MODULE_CHECK=1 still passes preflight"
  want_no_grep "cannot resolve module versions" "$ROOT/run.out" "SKIP_MODULE_CHECK=1 silences the probe"

  # The probe must stay read-only, and this is asserted on the command rather than on its effect
  # deliberately. `go get` is the obvious command to reach for here and it rewrites go.mod and go.sum
  # in whatever module it runs in — but no test of the failing path can demonstrate that, because a
  # fetch that fails writes nothing. An assertion on the tree would pass either way: decoration.
  probe_cmd=$(grep -F 'golang.org/x/tools@latest' "$HARNESS/run.sh" | grep -F 'cd "$probe_dir"')
  contains "go list -m" "$probe_cmd"; want $? "the probe uses a read-only go subcommand, not go get"
  [ -z "$(git -C "$REPO" status --porcelain)" ]; want $? "and the target repo is clean afterwards"
}

# A relative LOGS, which is what the README's own non-Docker invocation passes. run.sh cds into the
# target repo to work, so every path derived from LOGS has to be absolute before that — otherwise the
# narration, the state files and the per-invocation logs all quietly repoint into the target repo.
#
# Every other scenario passes an absolute LOGS, which is exactly why none of them caught this.
scenario_relative_logs() {
  setup
  RUN_CWD="$ROOT"
  run_loop happy MAX_ISSUES=1 LOGS=logs

  want "$RC" "exits 0"
  want_no_grep "No such file or directory" "$ROOT/run.out" "nothing failed to write"
  # The narration before the cd lands in the right place either way; it is the lines *after* it that
  # move, so assert on content rather than on the file existing.
  want_grep "#2 DONE" "$ROOT/logs/run.log" "the run log is complete, not truncated at the cd into the repo"
  want_grep "round 1: gate clean" "$ROOT/logs/run.log" "including the per-round narration"
  [ -f "$ROOT/logs/2-implement.json" ]; want $? "per-invocation logs went to LOGS, not into the repo"
  [ ! -e "$REPO/logs" ]; want $? "no log directory was created inside the target repo"
  contains "logs/" "$(git -C "$REPO" show --stat HEAD)"
  [ $? -ne 0 ]; want $? "and no logs were committed into the target repo by git add -A"
}

# Uncommitted work in the target repo when the run starts. `git add -A` at the end of each issue does
# not distinguish it from the implementer's own edits, so it would land in the first issue's commit —
# and the case this really guards is a second run started after one was killed mid-issue.
scenario_dirty() {
  setup
  printf 'half an edit from a killed run\n' > "$REPO/WIP.txt"
  printf 'and a modification to a tracked file\n' >> "$REPO/README.md"
  run_loop happy MAX_ISSUES=1

  [ "$RC" -ne 0 ]; want $? "refuses to start"
  want_grep "uncommitted changes" "$ROOT/run.out" "and says why"
  want_grep "WIP.txt" "$ROOT/run.out" "naming the files, so the fix is obvious"
  [ ! -f "$STUB_DIR/calls" ]; want $? "no model invocation was made, so it costs nothing"
  [ "$(commits)" = 1 ]; want $? "nothing was committed"

  # The override, for the case where the changes are genuinely meant to go in.
  run_loop happy MAX_ISSUES=1 ALLOW_DIRTY=1
  want "$RC" "ALLOW_DIRTY=1 runs anyway"
  want_grep "will be committed as part of the first issue" "$ROOT/run.out" "having said what it is about to do"
  contains "WIP.txt" "$(git -C "$REPO" show --stat HEAD)"
  want $? "and the pre-existing change is in the issue's commit, as warned"
}

# The evidence pack the retrospective reasons from. Every number in it is arithmetic over the
# artifacts, so the artifacts are written by hand here rather than by a run: that is the only way to
# assert the arithmetic is right instead of merely self-consistent.
scenario_retro_pack() {
  setup
  printf '# Cache the extraction graph\n\nbody enough to be a description\n' > "$LOGS/issue-11.md"
  printf '# Something smaller\n\nalso a description\n'                      > "$LOGS/issue-2.md"
  jq -n '{total_cost_usd: 0.5}' > "$LOGS/11-implement.json"
  jq -n '{total_cost_usd: 0.5}' > "$LOGS/2-implement.json"

  # #2: the gate failed in round 1, the fixer ran, round 2 was clean and all three critics passed.
  printf 'VIOLATION: a test was deleted.\n' > "$LOGS/2-gate-1.txt"
  jq -n '{total_cost_usd: 0.25}' > "$LOGS/2-fix-1.json"
  : > "$LOGS/2-gate-2.txt"
  printf '+++ b/a.go\n+++ b/a_test.go\n' > "$LOGS/2-diff-2.patch"
  for role in review idiom tests; do
    jq -n '{verdict:"PASS", findings: []}' > "$LOGS/2-$role-2.verdict.json"
  done
  printf '2\n' > "$LOGS/landed"

  # #11: one round, gate clean, the test critic objected, and it was abandoned there.
  : > "$LOGS/11-gate-1.txt"
  printf '+++ b/graph.go\n' > "$LOGS/11-diff-1.patch"
  jq -n '{verdict:"PASS", findings: []}' > "$LOGS/11-review-1.verdict.json"
  jq -n '{verdict:"PASS", findings: []}' > "$LOGS/11-idiom-1.verdict.json"
  jq -n '{verdict:"FAIL", findings: [{file:"g.go",problem:"p",fix:"f"}]}' > "$LOGS/11-tests-1.verdict.json"
  printf '11\n' > "$LOGS/skipped"

  run_retro PACK_ONLY=1 --

  want "$RC" "exits 0"
  # Glob order is lexical, so an unsorted list reads "11 2" — and then the report's own headings are
  # in an order that matches nothing a human is looking at.
  want_grep "Issues in this batch: 2 11" "$ROOT/retro.out" "issues discovered from artifacts, sorted numerically"
  want_grep "Outcome: landed, issue left open (NO_PUSH)" "$ROOT/retro.out" "a landed-but-open issue is labelled as such"
  want_grep "Outcome: ABANDONED" "$ROOT/retro.out" "an abandoned issue is not reported as landed"
  want_grep "Total spend: \$0.75" "$ROOT/retro.out" "cost is summed across every invocation for the issue"
  want_grep "round 1: gate FAILED (1 VIOLATION" "$ROOT/retro.out" "a failed gate round is identified, with the violation count"
  want_grep "fixer ran" "$ROOT/retro.out" "and that the fixer was sent after it"
  want_grep "round 2: gate clean" "$ROOT/retro.out" "a clean round is distinguished from a failed one"
  want_grep "over 2 file(s)" "$ROOT/retro.out" "the diff size and file count come from the patch"
  want_grep "tests FAIL (1 finding(s))" "$ROOT/retro.out" "per-critic verdicts and finding counts are per round"
  want_no_grep "round 3" "$ROOT/retro.out" "rounds that never ran are not invented"
}

# The retrospective end to end, off the back of a real batch: RETRO=1 must review *this* batch, must
# not be able to fail the run, and must be as token-starved as every other model invocation.
scenario_retro() {
  setup
  printf '2\n3\n' > "$STUB_DIR/open-issues"
  # A stale artifact from an earlier batch into the same log directory. The retrospective must not
  # pick it up: LOGS accumulates, and "which issues did tonight touch" is a different question.
  jq -n '{total_cost_usd: 9.99}' > "$LOGS/7-implement.json"

  run_loop happy MAX_ISSUES=2 RETRO=1 GH_TOKEN=stub-token-must-not-leak

  want "$RC" "exits 0"
  want_grep "retro: reviewing issue(s) 2 3" "$ROOT/run.out" "the retrospective ran on the batch that just landed"
  report=$(echo "$LOGS"/retro-*.md)
  [ -f "$report" ]; want $? "a report was written to the log directory"
  want_grep "## Verdict" "$report" "and it is the model's markdown, not the envelope"
  want_grep "## Verdict" "$ROOT/run.out" "the report is on stdout too, so nohup catches it for the log sync"

  pack=$(echo "$STUB_DIR"/retro-*.stdin)
  want_grep "You are reviewing" "$pack" "the prompt reached the invocation"
  want_grep "Issue #2" "$pack" "the pack covers the batch"
  want_grep "Issue #3" "$pack" "both of it"
  want_no_grep "Issue #7" "$pack" "and not an issue from an earlier batch in the same log directory"
  want_grep "round 1: gate clean" "$pack" "with the per-round evidence"

  # The harness's one enforced boundary, asserted for every invocation the run made rather than
  # described in a comment: a prompt says "do not push", `env -u GH_TOKEN` is what means it cannot.
  if grep -qv '(unset)$' "$STUB_DIR/tokens" 2>/dev/null; then
    bad "GH_TOKEN reached a model invocation: $(grep -v '(unset)$' "$STUB_DIR/tokens" | head -1)"
  else
    ok "GH_TOKEN reached no model invocation, retrospective included"
  fi
}

# The carry-over without the abandonment that queues it. The retry phase is only reachable when the
# main pass ends by draining its queue or filling MAX_ISSUES: a run that hits its spend cap, trips the
# consecutive-abandon breaker or is stopped by hand leaves its abandoned issues with no re-attempt at
# all — and so does handing one to a second host to work through in parallel. In every one of those the
# findings that say why the attempt failed are sitting in LOGS and the re-attempt is, mechanically, a
# first attempt. CARRY_FINDINGS is what stops that evidence being re-derived at full price.
scenario_carry_across_runs() {
  setup

  # A previous run, which abandons the issue and leaves its verdicts behind.
  run_loop always_fail MAX_ISSUES=1
  want_grep "#2 ABANDONED" "$ROOT/run.out" "the first run abandoned the issue"
  # Both runs use the same TAG, so the first run's artifacts have to be copied aside before the second
  # overwrites them — which is the assertion below: attempt one had nothing to carry.
  cp "$STUB_DIR/2-implement.stdin" "$ROOT/first-implement.stdin"
  want_no_grep "Outstanding findings from an earlier attempt" "$ROOT/first-implement.stdin" \
            "and its own implementer had nothing to carry"

  # What an operator does to hand the issue back to the loop: clear the entry that says it needs a
  # human. On another host this is the same step, after the verdicts are copied across.
  : > "$LOGS/skipped"
  run_loop happy MAX_ISSUES=1 CARRY_FINDINGS=1

  want "$RC" "the second run exits cleanly"
  want_grep "#2 DONE" "$ROOT/run.out" "and lands the issue the first run gave up on"
  want_grep "Outstanding findings from an earlier attempt" "$STUB_DIR/2-implement.stdin" \
            "the fresh implementer is told an abandoned attempt exists"
  want_grep "Still not right." "$STUB_DIR/2-implement.stdin" \
            "with the findings that were outstanding when it was parked"
  want_grep "you are not free to reproduce these" "$STUB_DIR/2-implement.stdin" \
            "framed as constraints rather than as a worklist"
  # One, not three: in this fixture the correctness critic is the only one still objecting in the round
  # the attempt was parked on, and what is carried is what was outstanding — not every finding the
  # attempt ever collected.
  want_grep "carrying 1 outstanding finding(s)" "$ROOT/run.out" "and the carry-over is narrated"
  want_grep "From the correctness reviewer" "$LOGS/2-carryover.md" \
            "attributed to the critic that raised it, as the retry phase attributes it"
}

# Off by default, and the default is the whole safety of the thing: LOGS accumulates every batch ever
# run into it, so an ordinary run must not prompt its implementer with an attempt it knows nothing
# about and cannot see.
scenario_carry_default_off() {
  setup
  run_loop always_fail MAX_ISSUES=1
  : > "$LOGS/skipped"
  run_loop happy MAX_ISSUES=1

  want "$RC" "the run exits cleanly"
  want_no_grep "Outstanding findings from an earlier attempt" "$STUB_DIR/2-implement.stdin" \
            "no carry-over without CARRY_FINDINGS, even with an earlier attempt's verdicts on disk"
  want_no_grep "carrying" "$ROOT/run.out" "and nothing is narrated"
}

# --- driver -----------------------------------------------------------------------

ALL="happy fixround testcritic garbage abandon late_pass nodiff no_push two_issues bounded retry carry_across_runs carry_default_off spend double_critic kind_pinning test_files_guard push_credential workflow_scope abandon_count pushfail breaker preflight moduleproxy relative_logs dirty retro_pack retro"
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

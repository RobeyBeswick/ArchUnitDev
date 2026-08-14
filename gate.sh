#!/usr/bin/env bash
# Deterministic checks. Cheap, no model involved — run before the reviewers so that no tokens are
# ever spent reviewing code that does not compile, and so that a gate failure does not consume one
# of the issue's review rounds.
#
# Exit 0 = clean, non-zero = findings on stdout for the fixer to read.
#
# The architecture rules that used to live here as greps now live in the target repo's
# .golangci.yml, as depguard rules against the resolved import graph. That is strictly better: an
# aliased, blank or line-wrapped import cannot slip past depguard, and the implementer can run the
# same check itself while working. What stays here is everything golangci-lint structurally cannot
# see — cross-compilation, module hygiene, and the reward-hacking guards.
set -uo pipefail

cd "${REPO:-/work/repo}" || exit 1
LINT="${LINT:-golangci-lint}"
fail=0
step() { printf '\n--- %s\n' "$*"; }

# Some checks need the network (the module proxy, the vulnerability database). A network failure is
# not a code defect, and failing the gate for one would send the fixer off to repair something it
# cannot reach. Warn and carry on instead.
looks_like_network_trouble() {
  printf '%s' "$1" | grep -qiE 'dial tcp|no such host|i/o timeout|lookup .* on |connection refused|proxy.golang.org|TLS handshake|certificate'
}

if [ -f go.mod ]; then
  step "go build ./..."
  go build ./... 2>&1 || fail=1

  step "go vet ./..."
  # `go test` only runs a 10-analyzer subset of vet, so this is not redundant with the test step:
  # copylocks, unusedresult, stdversion, lostcancel, structtag and composites only run here.
  go vet ./... 2>&1 || fail=1

  if command -v "$LINT" >/dev/null 2>&1; then
    step "$LINT config verify"
    # A typo'd key in .golangci.yml is otherwise ignored in silence — which would mean the
    # architecture rules below stop being enforced without anything going red.
    "$LINT" config verify 2>&1 || fail=1

    step "$LINT fmt --diff"
    # Replaces `gofmt -l .`: also covers gofumpt's rules and import grouping, which gofmt does not.
    fmt_diff=$("$LINT" fmt --diff 2>&1)
    if [ -n "$fmt_diff" ]; then
      printf 'formatting is not clean. Run `%s fmt ./...`:\n%s\n' "$LINT" "$fmt_diff"
      fail=1
    fi

    step "$LINT run ./..."
    # This is where AGENTS.md's four dependency rules, the purity rule, the
    # globs-compile-to-regex-in-one-place rule and the library-hygiene rules are enforced.
    # Captured rather than piped: with pipefail, a `grep -v` that filters away every line exits 1
    # and would fail the gate on a clean run.
    lint_out=$("$LINT" run ./... 2>&1)
    lint_rc=$?
    printf '%s\n' "$lint_out" | grep -v '^level=warning'
    [ "$lint_rc" -eq 0 ] || fail=1
  else
    printf '\n!!! %s is NOT INSTALLED. The architecture rules, the dependency rules and the\n' "$LINT"
    printf '!!! doc-comment rules are NOT being enforced on this run. Falling back to greps.\n'
    printf '!!! Install golangci-lint (>= v2.5.0) — run.sh refuses an unattended run without it.\n'
    grep_dependency_rules=1
  fi

  step "go test -race -shuffle=on"
  # -covermode=atomic is required with -race; set/count corrupt their counters under concurrency.
  # -shuffle=on prints its seed, so a shuffle-dependent failure is reproducible from this log.
  # The profile goes to the log directory, not the repo: run.sh stages everything with `git add -A`,
  # so a cover.out in the working tree would be committed.
  go test -race -shuffle=on -count=1 -covermode=atomic \
    -coverprofile="${LOGS:-${TMPDIR:-/tmp}}/cover.out" ./... 2>&1 || fail=1

  step "go mod tidy -diff"
  tidy_out=$(go mod tidy -diff 2>&1)
  tidy_rc=$?
  if [ "$tidy_rc" -ne 0 ]; then
    if looks_like_network_trouble "$tidy_out"; then
      printf 'WARNING: could not reach the module proxy, skipping. Not treated as a failure:\n%s\n' "$tidy_out"
    else
      printf 'go.mod/go.sum are not tidy. Run `go mod tidy`:\n%s\n' "$tidy_out"
      fail=1
    fi
  fi

  step "cross-compile"
  # A darwin/arm64 box never catches a hardcoded '/' path separator or a 32-bit int assumption,
  # and this library walks file paths for a living.
  for target in "windows amd64" "linux 386"; do
    set -- $target
    out=$(GOOS="$1" GOARCH="$2" go build ./... 2>&1) || {
      printf 'does not build for GOOS=%s GOARCH=%s:\n%s\n' "$1" "$2" "$out"
      fail=1
    }
  done

  if command -v govulncheck >/dev/null 2>&1; then
    step "govulncheck ./..."
    vuln_out=$(govulncheck ./... 2>&1)
    if [ $? -ne 0 ]; then
      if looks_like_network_trouble "$vuln_out"; then
        printf 'WARNING: could not reach the vulnerability database, skipping.\n'
      else
        printf '%s\n' "$vuln_out"
        fail=1
      fi
    fi
  fi
else
  step "no go.mod yet — skipping the Go toolchain checks"
fi

# --- fallback only: the dependency rules, if golangci-lint was missing ------------------------
if [ -n "${grep_dependency_rules:-}" ]; then
  step "FALLBACK dependency rule: domain modules must not import each other"
  modules="files layers slices metrics graph"
  for m in $modules; do
    [ -d "$m" ] || continue
    for other in $modules; do
      [ "$m" = "$other" ] && continue
      if grep -rqE "ArchUnitGo/$other(/|\")" "$m" --include='*.go' 2>/dev/null; then
        printf 'VIOLATION: domain module %s imports domain module %s. ' "$m" "$other"
        printf 'AGENTS.md dependency rule 2 forbids this — the shared helper belongs in common/.\n'
        grep -rnE "ArchUnitGo/$other(/|\")" "$m" --include='*.go' 2>/dev/null
        fail=1
      fi
    done
  done

  step "FALLBACK dependency rule: common must not import a domain module"
  if [ -d common ]; then
    for m in $modules; do
      if grep -rqE "ArchUnitGo/$m(/|\")" common --include='*.go' 2>/dev/null; then
        printf 'VIOLATION: common imports domain module %s. AGENTS.md dependency rule 1 forbids this.\n' "$m"
        fail=1
      fi
    done
  fi
fi

# --- reward-hacking guards: no linter catches these -------------------------------------------
# The cheapest way to make `go test` pass is to stop running the tests.

step "no skipped or disabled tests"
# An escape hatch exists on purpose, because a genuinely platform-specific skip would otherwise
# deadlock the loop — but it has to be written down, so it shows up in the diff and in review.
if grep -rnE '\b[tbf]\.Skip(Now|f)?\(' . --include='*_test.go' 2>/dev/null | grep -v 'ALLOW-SKIP:'; then
  printf 'VIOLATION: a test skips itself. Fix the code, not the test.\n'
  printf 'If the skip is genuinely necessary, put `ALLOW-SKIP: <reason>` on the same line.\n'
  fail=1
fi
if grep -rnE '^[[:space:]]*//[[:space:]]*func (Test|Fuzz|Example)' . --include='*_test.go' 2>/dev/null; then
  printf 'VIOLATION: a test function is commented out. Fix the code, not the test.\n'
  fail=1
fi

step "the test count did not go down"
# The one thing coverage cannot tell you: whether a test was deleted. Needs BASE from run.sh; when
# it is not set (a manual invocation) this check simply does not apply.
if [ -n "${BASE:-}" ] && git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  base_tests=$(git grep -hE '^func (Test|Fuzz|Example)' "$BASE" -- '*_test.go' 2>/dev/null | wc -l | tr -d ' ')
  now_tests=$(grep -rhE '^func (Test|Fuzz|Example)' . --include='*_test.go' 2>/dev/null | wc -l | tr -d ' ')
  printf 'test functions: %s at base, %s now\n' "${base_tests:-0}" "${now_tests:-0}"
  if [ "${now_tests:-0}" -lt "${base_tests:-0}" ]; then
    printf 'VIOLATION: there are fewer test functions than at the base commit. A test was deleted.\n'
    printf 'If a test was genuinely obsolete, say so in NOTES.md with a WHY: line.\n'
    fail=1
  fi
else
  printf 'BASE not set or not a valid revision — skipping\n'
fi

# Every `const Kind... = "literal"` has its *string value* asserted somewhere in the tests.
#
# The failure this catches has no other net. Every test in the tree compares `Kind()` against the
# constant, which is a tautology: respell the constant and the whole suite stays green — including
# respelling it onto a collision with a sibling kind, which the code says must not happen. The test
# critic found exactly this on issue #21 and it cost a full round ($5.05 of critics and fixer) to
# report and fix something a grep decides.
#
# Base-relative, like the test count above, and for the same reason: `KindFileDependency` landed
# unpinned in #20 with all three critics passing it, and a gate that failed on the tree's existing
# holes would blame the next issue's implementer for them and burn its rounds on somebody else's
# work. What is forbidden is *adding* one.
step "every violation-kind string value is pinned by a literal in a test"
# <rev|""> -> "NAME LITERAL" per line, from the non-test sources.
kind_consts() {
  if [ -n "$1" ]; then
    git grep -nE 'const Kind[A-Za-z0-9_]+ [A-Za-z0-9_.]+ = "[a-z0-9-]+"' "$1" -- '*.go' 2>/dev/null
  else
    grep -rnE 'const Kind[A-Za-z0-9_]+ [A-Za-z0-9_.]+ = "[a-z0-9-]+"' . --include='*.go' 2>/dev/null
  fi | grep -v '_test\.go' \
     | sed -E 's/.*const (Kind[A-Za-z0-9_]+) [A-Za-z0-9_.]+ = "([a-z0-9-]+)".*/\1 \2/' \
     | sort -u
}
# <literal> <rev|""> -> 0 if some test file contains it as a quoted string.
kind_pinned() {
  if [ -n "$2" ]; then git grep -qF "\"$1\"" "$2" -- '*_test.go' 2>/dev/null
  else grep -rqF "\"$1\"" . --include='*_test.go' 2>/dev/null; fi
}
# A here-doc rather than a pipe into `while`: a pipeline's loop body runs in a subshell, so
# everything it accumulated is discarded at the `done`.
unpinned_now=""
while read -r kname klit; do
  [ -n "$kname" ] || continue
  kind_pinned "$klit" "" || unpinned_now="$unpinned_now $kname"
done <<EOF
$(kind_consts "")
EOF
if [ -n "${BASE:-}" ] && git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  unpinned_base=""
  while read -r kname klit; do
    [ -n "$kname" ] || continue
    kind_pinned "$klit" "$BASE" || unpinned_base="$unpinned_base $kname"
  done <<EOF
$(kind_consts "$BASE")
EOF
  added=""
  for kname in $unpinned_now; do
    case " $unpinned_base " in *" $kname "*) ;; *) added="$added $kname" ;; esac
  done
  if [ -n "$added" ]; then
    printf 'VIOLATION: the string value of%s is asserted nowhere in the tests.\n' "$added"
    printf 'Every test compares Kind() against the constant, which passes whatever the constant says —\n'
    printf 'so respelling it, including onto a collision with another kind, leaves the suite green.\n'
    printf 'Assert the literal in a test, as the sibling kinds already do.\n'
    fail=1
  elif [ -n "$unpinned_now" ]; then
    printf 'unpinned at the base commit too, so not this issue to fix:%s\n' "$unpinned_now"
  fi
else
  printf 'BASE not set or not a valid revision — reporting only:%s\n' "${unpinned_now:- none unpinned}"
fi

step "at least one test exists"
if [ -f go.mod ] && ! find . -name '*_test.go' -not -path './.git/*' | grep -q .; then
  printf 'VIOLATION: the module has no test files at all.\n'
  fail=1
fi

exit $fail

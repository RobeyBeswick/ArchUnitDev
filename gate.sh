#!/usr/bin/env bash
# Deterministic checks. Cheap, no model involved — run before the reviewers so that
# no tokens are ever spent reviewing code that does not compile.
# Exit 0 = clean, non-zero = findings on stdout for the fixer to read.
set -uo pipefail

cd "${REPO:-/work/repo}" || exit 1
fail=0
step() { printf '\n--- %s\n' "$*"; }

if [ -f go.mod ]; then
  step "go build ./..."
  go build ./... 2>&1 || fail=1

  step "go vet ./..."
  go vet ./... 2>&1 || fail=1

  step "gofmt -l ."
  unformatted=$(gofmt -l . 2>&1)
  if [ -n "$unformatted" ]; then
    printf 'these files are not gofmt-clean, run gofmt -w on them:\n%s\n' "$unformatted"
    fail=1
  fi

  step "go test ./..."
  go test ./... 2>&1 || fail=1
else
  step "no go.mod yet — skipping the Go toolchain checks"
fi

# AGENTS.md dependency rule 2: domain modules must not depend on each other.
# Called out there as the rule that decays first, so it gets a check rather than trust.
step "dependency rule: domain modules must not import each other"
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

# AGENTS.md dependency rule 1: common depends on nothing but the stdlib and the analysis toolchain.
step "dependency rule: common must not import a domain module"
if [ -d common ]; then
  for m in $modules; do
    if grep -rqE "ArchUnitGo/$m(/|\")" common --include='*.go' 2>/dev/null; then
      printf 'VIOLATION: common imports domain module %s. AGENTS.md dependency rule 1 forbids this.\n' "$m"
      fail=1
    fi
  done
fi

# Reward-hacking guard: the cheapest way to make `go test` pass is to stop running the tests.
step "no skipped or disabled tests"
if grep -rn 'e\?t\.Skip\|^\s*//\s*func Test' . --include='*_test.go' 2>/dev/null; then
  printf 'VIOLATION: a test is skipped or commented out. Fix the code, not the test.\n'
  fail=1
fi

step "at least one test exists"
if [ -f go.mod ] && ! find . -name '*_test.go' -not -path './.git/*' | grep -q .; then
  printf 'VIOLATION: the module has no test files at all.\n'
  fail=1
fi

exit $fail

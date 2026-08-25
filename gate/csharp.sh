#!/usr/bin/env bash
# Deterministic checks for a C# target repo. Cheap, no model involved — run before the reviewers so
# that no tokens are ever spent reviewing code that does not compile, and so that a gate failure does
# not consume one of the issue's review rounds.
#
# Exit 0 = clean, non-zero = findings on stdout for the fixer to read.
#
# The analogue of gate/go.sh: same shape, C# toolchain. Where Go had golangci-lint + a .golangci.yml
# holding the architecture rules, C# has Roslyn analyzers, .editorconfig and the SDK's built-in
# `dotnet format` — which, as with Go, means the architecture rules belong in the target repo's
# configuration (an .editorconfig / Directory.Build.props), not here. What stays here is everything
# the toolchain structurally cannot see: restore hygiene, cross-RID builds, and the reward-hacking
# guards. This file is the reference implementation; a new language's gate is written as a sibling.
set -uo pipefail

cd "${REPO:-/work/repo}" || exit 1
fail=0
step() { printf '\n--- %s\n' "$*"; }

# Some checks need the network (the NuGet feed, the vulnerability database). A network failure is
# not a code defect, and failing the gate for one would send the fixer off to repair something it
# cannot reach. Warn and carry on instead. Same reasoning as gate/go.sh; NuGet restore failures speak
# in NUxxxx codes and host-resolution errors, which is what the extra patterns here are for.
looks_like_network_trouble() {
  grep -qiE 'dial tcp|no such host|i/o timeout|lookup .* on |connection refused|TLS handshake|certificate|NU1301|NU1101|nuget\.org|could not connect|No such host is known|name or service not known' <<<"$1"
}

# A project to build. A C# repo announces itself with a solution or a project file, and the gate
# runs its toolchain only then — a repo with neither is a repo the guards alone can police, exactly
# like the no-go.mod branch of gate/go.sh. Keeping the guard-only mode means the harness tests run
# without dotnet on PATH at all. `-print -quit` into a command substitution, never `| grep -q`: grep
# exits on the first match, find dies of SIGPIPE, and under pipefail the pipeline reports 141 — the
# exact race documented on gate/go.sh's "at least one test exists" check.
project_root=""
if [ -n "$(find . -maxdepth 2 \( -name '*.sln' -o -name '*.slnx' -o -name '*.csproj' \) \
          -not -path './.git/*' -print -quit 2>/dev/null)" ]; then
  project_root="."
fi

if [ -n "$project_root" ]; then
  step "dotnet restore"
  # Restore is the network-dependent step and the one that can hang: a blocked feed does not error,
  # it waits. So it is separated from build, and a restore that fails for a network reason warns
  # rather than fails — a build against a fully cached feed is still meaningful. Same shape as the
  # Go gate's `go mod tidy -diff` handling.
  restore_out=$(dotnet restore 2>&1)
  if [ $? -ne 0 ]; then
    if looks_like_network_trouble "$restore_out"; then
      printf 'WARNING: could not reach the NuGet feed, skipping restore. Not treated as a failure:\n%s\n' "$restore_out"
    else
      printf '%s\n' "$restore_out"
      fail=1
    fi
  fi

  step "dotnet build --no-restore"
  build_out=$(dotnet build --no-restore 2>&1)
  if [ $? -ne 0 ]; then
    printf '%s\n' "$build_out"
    fail=1
  fi

  step "dotnet format --verify-no-changes"
  # The analogue of `golangci-lint fmt --diff` / `gofmt -l`: whitespace, style and the rules the
  # .editorconfig enables, reported without applying. `--no-restore` so a format check does not
  # re-hit the feed.
  format_out=$(dotnet format --verify-no-changes --no-restore 2>&1)
  if [ $? -ne 0 ]; then
    printf 'formatting is not clean. Run `dotnet format`:\n%s\n' "$format_out"
    fail=1
  fi

  step "dotnet test --no-build"
  # No `--collect` coverage: it writes a TestResults/ directory into the working tree, which run.sh
  # would commit with `git add -A` — the same reason gate/go.sh sends its cover.out to $LOGS.
  dotnet test --no-build 2>&1 || fail=1

  step "cross-RID build"
  # A linux box never catches a hardcoded '\\' path separator or a Windows-only API, and this library
  # walks file paths for a living — the same reasoning as gate/go.sh's GOOS/GOARCH loop. `dotnet
  # publish -r win-x64` is the cross-compile analogue. --no-self-contained keeps it from producing a
  # runtime bundle; --no-restore keeps it from the feed. First use downloads the RID runtime pack, so
  # a network failure here warns rather than fails.
  out=$(dotnet publish -r win-x64 --no-restore --no-self-contained -o "${TMPDIR:-/tmp}/archunitdev-publish" 2>&1)
  if [ $? -ne 0 ]; then
    if looks_like_network_trouble "$out"; then
      printf 'WARNING: could not fetch the win-x64 runtime pack, skipping the cross-RID build:\n%s\n' "$out"
    else
      printf 'does not build for win-x64:\n%s\n' "$out"
      fail=1
    fi
  fi

  if command -v dotnet >/dev/null 2>&1; then
    step "dotnet list package --vulnerable"
    vuln_out=$(dotnet list package --vulnerable 2>&1)
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
  step "no .sln/.slnx/.csproj yet — skipping the dotnet toolchain checks"
fi

# --- reward-hacking guards: no linter catches these -------------------------------------------
# The cheapest way to make `dotnet test` pass is to stop running the tests. These are the C# spellings
# of the guards in gate/go.sh: a skipped test, a commented-out test, a shrinking test count, a suite
# that is not there. What gate/go.sh's `const Kind...` pinning check is *for* — a tautological
# assertion that cannot catch a respelled literal — is the same class of defect here, but its shape
# depends on how the target repo models violation kinds (an enum? a record?), so it belongs in the
# target repo's analyzer config or AGENTS.md, not in this language-generic file.

step "no skipped or disabled tests"
# xUnit/MSTest: [Fact(Skip = "...")] / [Theory(Skip = "...")] / [TestMethod(Skip = "...")].
# NUnit: [Ignore]. An escape hatch exists on purpose, mirroring gate/go.sh's ALLOW-SKIP:.
if grep -rnE '\[(Fact|Theory|Test|TestMethod)\([^]]*Skip[[:space:]]*=' . --include='*.cs' 2>/dev/null \
     | grep -v 'ALLOW-SKIP:'; then
  printf 'VIOLATION: a test skips itself. Fix the code, not the test.\n'
  printf 'If the skip is genuinely necessary, put `ALLOW-SKIP: <reason>` on the same line.\n'
  fail=1
fi
if grep -rnE '\[Ignore([^]]*)\]' . --include='*.cs' 2>/dev/null | grep -v 'ALLOW-SKIP:'; then
  printf 'VIOLATION: a test is ignored (NUnit [Ignore]). Fix the code, not the test.\n'
  printf 'If the ignore is genuinely necessary, put `ALLOW-SKIP: <reason>` on the same line.\n'
  fail=1
fi

step "no commented-out test methods"
if grep -rnE '^[[:space:]]*//[[:space:]]*\[(Fact|Theory|Test|TestMethod|TestCase)' . --include='*.cs' 2>/dev/null; then
  printf 'VIOLATION: a test method is commented out. Fix the code, not the test.\n'
  fail=1
fi

step "the test count did not go down"
# The one thing coverage cannot tell you: whether a test was deleted. Counts test *attributes*, which
# is what declares a test in xUnit/NUnit/MSTest. The leading ^[[:space:]]*[ makes a commented-out
# attribute invisible to this count, and the "no commented-out tests" guard above makes one that is
# commented out a violation on its own. Needs BASE from run.sh; when it is not set (a manual
# invocation) this check simply does not apply.
if [ -n "${BASE:-}" ] && git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  base_tests=$(git grep -hE '^[[:space:]]*\[(Fact|Theory|Test|TestMethod|TestCase)\b' "$BASE" -- '*.cs' 2>/dev/null | wc -l | tr -d ' ')
  now_tests=$(grep -rhE '^[[:space:]]*\[(Fact|Theory|Test|TestMethod|TestCase)\b' . --include='*.cs' 2>/dev/null | wc -l | tr -d ' ')
  printf 'test methods: %s at base, %s now\n' "${base_tests:-0}" "${now_tests:-0}"
  if [ "${now_tests:-0}" -lt "${base_tests:-0}" ]; then
    printf 'VIOLATION: there are fewer test methods than at the base commit. A test was deleted.\n'
    printf 'If a test was genuinely obsolete, say so in NOTES.md with a WHY: line.\n'
    fail=1
  fi
else
  printf 'BASE not set or not a valid revision — skipping\n'
fi

step "at least one test exists"
# The same guard as gate/go.sh, and the same SIGPIPE-safe shape (`-print -quit`, never `| grep -q`):
# a suite with no test attributes at all is a suite that cannot fail. Gated on a project existing —
# a repo with no project yet has nothing to test.
if [ -n "$project_root" ] && [ -z "$(grep -rhE '^[[:space:]]*\[(Fact|Theory|Test|TestMethod|TestCase)\b' . --include='*.cs' 2>/dev/null | head -1)" ]; then
  printf 'VIOLATION: the solution has no test methods at all.\n'
  fail=1
fi

exit $fail
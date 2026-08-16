#!/usr/bin/env bash
#
# ArchUnitDev — an unattended implement / review / fix loop.
#
# For each open issue in the target repo, lowest number first:
#   implement  ->  [ deterministic gate  ->  reviewer + idiom critic  ->  fix ] x MAX_ROUNDS
#              ->  commit, push, close the issue
#
# Then, once the queue is done, one more attempt at each issue this run abandoned — against the tree
# the batch finished on rather than the one it failed against. The backlog is in dependency order, so
# an abandonment leaves a hole with everything after it landing on top.
#
# State lives in git and in the GitHub issues. There is no database and no resume logic:
# the next issue is always "the lowest-numbered open one", so a killed run is restarted
# by running this script again.
#
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-/work/repo}"
LOGS="${LOGS:-$HARNESS/logs}"

# Absolute from here on, before anything derives a path from either. This script cds into the target
# repo to do its work, so a *relative* LOGS — which is exactly what the documented
# `LOGS=./logs ./run.sh` gives you — silently repoints everything at the target repo at that moment:
# `tee` fails on every line of narration, the skipped and landed lists read as absent so the queue
# forgets what it has already done, and any log that did get written would land inside the repository
# the loop then commits with `git add -A`.
mkdir -p "$LOGS" 2>/dev/null || { echo "FATAL: cannot create LOGS=$LOGS" >&2; exit 1; }
LOGS="$(cd "$LOGS" && pwd)"
[ -d "$REPO" ] && REPO="$(cd "$REPO" && pwd)"

MAX_ROUNDS="${MAX_ROUNDS:-3}"       # review/fix rounds before an issue is abandoned
# The critics, each backed by prompts/<role>.md. They run concurrently and every one must PASS.
# Adding a role here and a prompt file is the whole of adding a reviewer.
CRITICS=(review idiom tests)
MAX_ISSUES="${MAX_ISSUES:-0}"       # 0 = run until the queue is empty
TIMEOUT="${TIMEOUT:-30m}"           # wall clock per invocation
# Bedrock model IDs, not the "opus"/"sonnet" aliases: the aliases only resolve via
# ANTHROPIC_DEFAULT_*_MODEL, which lives in the host's ~/.claude/settings.json and is
# deliberately not carried into the container.
MODEL="${MODEL:-global.anthropic.claude-opus-5}"
FALLBACK_MODEL="${FALLBACK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-400000}"
NO_PUSH="${NO_PUSH:-}"              # set to 1 to commit locally but not push or close issues
MAX_CONSECUTIVE_ABANDONS="${MAX_CONSECUTIVE_ABANDONS:-2}"   # stop the run after this many in a row; 0 = never stop
RETRY_ABANDONED="${RETRY_ABANDONED-1}"    # re-attempt abandoned issues once the batch has grown under them; empty = off
# Carry a *previous* run's outstanding findings into a first attempt, the way the retry phase carries
# them into a second one. Off by default, because LOGS is long-lived: verdicts for an issue outlive the
# run that wrote them, and telling a fresh implementer about a parked attempt that is not on this host
# is a lie about what it is looking at.
#
# It exists because the retry phase is not always reachable. An issue abandoned by a run that then hit
# its spend cap, tripped the consecutive-abandon breaker, or was simply stopped never gets the
# re-attempt that would have carried its findings — and neither does one handed to a *different* host
# to work through in parallel. Both are the same situation: the evidence is on disk, the abandonment
# that would have queued it is not going to happen, and re-deriving it costs what it cost the first
# time. Set this when you have deliberately put an abandoned issue's verdicts where this run can read
# them.
CARRY_FINDINGS="${CARRY_FINDINGS:-}"
MAX_SPEND="${MAX_SPEND:-0}"         # dollars this run may spend before it stops at an issue boundary; 0 = no cap
DOUBLE_CRITICS="${DOUBLE_CRITICS-tests}"  # roles that run twice in round 1, findings unioned; empty = none

SCHEMA="$(cat "$HARNESS/schema/verdict.json")"
SKIPPED="$LOGS/skipped"          # abandoned: got no further after MAX_ROUNDS, needs a human
LANDED="$LOGS/landed"            # landed but deliberately left open, which only NO_PUSH does

touch "$SKIPPED" "$LANDED"

say() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOGS/run.log"; }
die() { say "FATAL: $*"; exit 1; }

# The skipped list, written once and unwritten when an issue stops needing a human. Both of these
# exist because the file is read as a set — by the queue, and by the retrospective to label an
# outcome — so a duplicate entry is a miscount and a stale one is a lie.
record_skipped() { grep -qx "$1" "$SKIPPED" 2>/dev/null || echo "$1" >> "$SKIPPED"; }
# awk, not `grep -v`: grep exits 1 when it selects no lines, so the idiomatic
# `grep -v "$1" f > tmp && mv tmp f` silently does nothing to a file whose every line matches — and a
# one-line skipped list being cleared is exactly the case that matters here.
forget_skipped() {
  grep -qx "$1" "$SKIPPED" 2>/dev/null || return 0
  awk -v n="$1" '$0 != n' "$SKIPPED" > "$SKIPPED.tmp" && mv "$SKIPPED.tmp" "$SKIPPED"
}

# How many issues *this* run abandoned and did not recover, and how many entries in the skipped list
# are somebody else's business. The end-of-run summary used to report `wc -l < $SKIPPED` as "abandoned",
# which is wrong in both directions the moment LOGS outlives a single batch — and LOGS is deliberately
# long-lived. It counted every abandonment any earlier batch ever recorded, and it counted issues an
# operator had put there by hand to hold them back.
#
# It said what it said out loud, too: host B landed all seven of its issues on 15 August and reported
# "7 issue(s) landed, 5 abandoned", the five being #30 and #31 (handed to a second host) and #41, #42
# and #44 (held until the two trees were merged). The same batch's retrospective then had to reason
# about a five-failure night that had not happened. That is the expensive part — this week already cost
# two retrospectives that drew confident conclusions from a number nobody had checked.
#
# The narrowing is an intersection with the issues this run touched, which the loop already tracks for
# the retrospective. `attempt > 1` landings call forget_skipped, so an issue abandoned in the main pass
# and recovered by the retry phase is correctly absent from both.
#
# The bash 3.2 +expansion guard, as everywhere else here: "${arr[@]}" on an empty array is an unbound
# variable under `set -u`, and a run that abandoned nothing has exactly that.
abandoned_this_run() {
  local n c=0
  for n in ${attempted_issues[@]+"${attempted_issues[@]}"}; do
    grep -qx "$n" "$SKIPPED" 2>/dev/null && c=$((c + 1))
  done
  printf '%s' "$c"
}
other_skipped_list() {
  local n out=""
  while read -r n; do
    [ -n "$n" ] || continue
    case " ${attempted_issues[*]-} " in *" $n "*) continue ;; esac
    out="${out:+$out }$n"
  done < "$SKIPPED"
  printf '%s' "$out"
}
other_skipped() {
  local l
  l=$(other_skipped_list)
  # Word count on the list, not a line count on the file: this must agree with what the list prints.
  set -- $l
  printf '%s' "$#"
}

# What this run has cost so far, in dollars, from the only authority on it: the total_cost_usd every
# invocation writes into its own result JSON.
#
# Two things make this a file scan rather than a variable. LOGS is long-lived and accumulates every
# batch ever run into it, so a glob over all of it answers a different question ("what has this log
# directory cost?") than the one a cap is about — hence RUN_MARKER, touched at startup, and -newer.
# And there is nowhere for an accumulator to live: work() runs inside a pipeline subshell and the
# critics run with `&`, so anything either of them adds to a shell variable is discarded when it
# exits. The files are the shared state; nothing else is.
RUN_MARKER="$LOGS/.run-started"
spend_this_run() {
  # -exec + batches, and jq prints one number per file, so awk sums across every batch. Piping the
  # list into xargs instead would split into several jq invocations and several separate sums.
  find "$LOGS" -maxdepth 1 -name '*.json' -newer "$RUN_MARKER" -exec jq -r '.total_cost_usd // 0' {} + 2>/dev/null \
    | awk '{ t += $1 } END { printf "%.2f", t + 0 }'
}
spend_all_time() {
  jq -s '[.[].total_cost_usd // 0] | add // 0' "$LOGS"/*.json 2>/dev/null \
    | awk '{ printf "%.2f", $1 + 0 }'
}

# --- preflight -------------------------------------------------------------------
# Every check here is something that otherwise fails silently or halfway through the night.

[ "$(id -u)" -ne 0 ] || die "refusing to run as root: Claude Code blocks --dangerously-skip-permissions for the root user. Run the container as a non-root user."
command -v claude >/dev/null || die "claude not on PATH"
command -v gh     >/dev/null || die "gh not on PATH"
command -v jq     >/dev/null || die "jq not on PATH"
command -v go     >/dev/null || say "WARNING: go not on PATH — the build and test gate will be skipped"

# A cap that does not parse as a number is worse than no cap: awk would compare it as a string and
# either never fire or fire before the first issue, and either way the operator believes they set one.
case "$MAX_SPEND" in
  ''|*[!0-9.]*|*.*.*) die "MAX_SPEND=$MAX_SPEND is not a dollar amount (a number like 400 or 12.50, or 0 for no cap)" ;;
esac

# `timeout` is coreutils: it is in the image, but not on a stock macOS box, where it is `gtimeout`
# or absent entirely. Resolve it once here — otherwise every invocation dies on "command not found"
# and the run burns the whole queue doing nothing.
if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_CMD=(timeout "$TIMEOUT");  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD=(gtimeout "$TIMEOUT"); TIMEOUT_BIN=gtimeout
else
  TIMEOUT_CMD=(); TIMEOUT_BIN=
  say "WARNING: neither timeout nor gtimeout is on PATH — invocations will run with no wall-clock limit and TIMEOUT=$TIMEOUT is ignored. A wedged invocation will hang the run. Install coreutils."
fi
[ -d "$REPO/.git" ] || die "$REPO is not a git repository (mount the target repo there, or set REPO)"

# Uncommitted work in the target repo at startup is not the loop's to commit, and it will commit it:
# each issue ends in `git add -A`, so whatever is already lying there lands in the first issue's
# commit, described as that issue's implementation. Under NO_PUSH nobody sees it until review, and by
# then the diff for the batch has someone else's half-finished edit sitting inside an unrelated
# commit. The usual cause is a previous run killed mid-issue, which is exactly when a second run is
# most likely to be started — and this is fatal rather than a warning because there is no way for the
# loop to tell whose changes they are.
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
  if [ -n "${ALLOW_DIRTY:-}" ]; then
    say "WARNING: $REPO has uncommitted changes and ALLOW_DIRTY is set — they will be committed as part of the first issue"
  else
    die "$REPO has uncommitted changes, and the first issue's 'git add -A' would commit them as its own work:
$(git -C "$REPO" status --short | head -20)
Commit them, stash them, or 'git checkout .' — or set ALLOW_DIRTY=1 if they are genuinely meant to go in."
  fi
fi

# The linter is where AGENTS.md's dependency rules, the purity rule and the doc-comment rules are
# actually enforced. Both failure modes below are silent — the gate goes green while checking much
# less than it claims to — which is exactly the kind of thing that must not be discovered in the
# morning, after a night of commits.
if [ -f "$REPO/go.mod" ] && [ -z "${ALLOW_NO_LINT:-}" ]; then
  command -v "${LINT:-golangci-lint}" >/dev/null \
    || die "${LINT:-golangci-lint} is not installed, so the gate cannot enforce the architecture rules in $REPO/.golangci.yml. Install golangci-lint >= v2.5.0, or set ALLOW_NO_LINT=1 to run with grep fallbacks and no lint enforcement."
  [ -f "$REPO/.golangci.yml" ] || [ -f "$REPO/.golangci.yaml" ] || [ -f "$REPO/.golangci.toml" ] \
    || die "no .golangci.yml in $REPO — golangci-lint would silently fall back to its five default linters and none of the dependency rules would be checked. Restore the config, or set ALLOW_NO_LINT=1."
fi

# Can this machine resolve a module version? That is a different question from whether the module
# cache is warm, and a warm cache does not answer it: adding a dependency needs a *version lookup*
# ("which version is @latest"), which has no cache fallback at all. A build against a settled go.mod
# works offline; the commit that first adds the dependency does not.
#
# It is worth 15 seconds here because of how it fails rather than whether it does. A blocked module
# proxy does not error, it hangs — measured at over 30s with no output and no rc — so the implementer
# spends its wall clock waiting, gets killed by TIMEOUT, and the issue comes back as unfinished work
# with nothing in the log pointing at DNS. The queue then does the same thing to every issue after it.
#
# A warning, not fatal: most issues add no dependency, and killing a night's run over a proxy that
# nothing in the queue needs would cost more than the failure it prevents. golang.org/x/tools is the
# module probed because it is the one this backlog actually reaches for — the extractor needs
# go/packages — so a failure here is a real blocker for a real issue rather than a synthetic one.
if [ -f "$REPO/go.mod" ] && command -v go >/dev/null 2>&1 && [ -z "${SKIP_MODULE_CHECK:-}" ]; then
  probe=()
  [ -n "$TIMEOUT_BIN" ] && probe=("$TIMEOUT_BIN" 15)
  # Run outside the repo: the probe must not be able to touch its go.mod or go.sum.
  probe_dir="${TMPDIR:-/tmp}"
  if ! (cd "$probe_dir" && ${probe[@]+"${probe[@]}"} go list -m -json golang.org/x/tools@latest) >/dev/null 2>&1; then
    say "WARNING: cannot resolve module versions — 'go list -m golang.org/x/tools@latest' failed or timed out. Any issue that adds a dependency will hang until TIMEOUT and come back unfinished. If proxy.golang.org is blocked here, GOPROXY=direct fetches straight from the VCS host (needs egress to go.googlesource.com). Issues that add no dependency are unaffected. Set SKIP_MODULE_CHECK=1 to silence this."
  fi
fi

# Auth. Three ways in; check the one actually configured, and fail now rather than on
# the first invocation an hour into the night.
if [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
  # The trap: AWS_PROFILE pointing at a credential_process that does
  # not exist inside the container. Unset it and let the instance profile answer.
  if [ -n "${AWS_PROFILE:-}" ] && ! command -v <credential-helper> >/dev/null 2>&1; then
    say "WARNING: AWS_PROFILE=$AWS_PROFILE is set but '<credential-helper>' is not on PATH — if that profile uses credential_process, credentials cannot resolve. Unset AWS_PROFILE to fall back to the EC2 instance profile."
  fi
  command -v aws >/dev/null || die "CLAUDE_CODE_USE_BEDROCK=1 but the aws CLI is not installed, so credentials cannot be verified"
  caller=$(aws sts get-caller-identity --query Arn --output text 2>&1) \
    || die "CLAUDE_CODE_USE_BEDROCK=1 but no usable AWS credentials: $caller"
  say "auth: Bedrock in ${AWS_REGION:-${AWS_DEFAULT_REGION:-unset-region}} as $caller"
  # Static creds in the environment do not refresh. Fine for a bounded smoke test; for an
  # unbounded run they die partway through the night, so that needs saying out loud.
  if [ -n "${AWS_SESSION_TOKEN:-}" ] && [ -z "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
    if [ "$MAX_ISSUES" -eq 0 ] && [ -z "${ALLOW_STATIC_CREDS:-}" ]; then
      die "refusing an unbounded run on static temporary credentials — they will expire partway through and every invocation after that fails. Use an EC2 instance profile, or set MAX_ISSUES to something that finishes inside their lifetime, or set ALLOW_STATIC_CREDS=1 to override."
    fi
    say "WARNING: static temporary credentials — these will NOT refresh. Fine for MAX_ISSUES=$MAX_ISSUES, not for a full run."
  fi
elif [ -n "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  say "auth: Anthropic API"
else
  die "no auth configured: set CLAUDE_CODE_USE_BEDROCK=1 with AWS credentials, or ANTHROPIC_API_KEY, or CLAUDE_CODE_OAUTH_TOKEN"
fi

cd "$REPO" || die "cannot cd to $REPO"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (set GH_TOKEN)"
git config user.email >/dev/null 2>&1 || die "git user.email is not configured in the container"
git remote get-url origin >/dev/null 2>&1 || die "no git remote named origin"

# git does not read GH_TOKEN. `gh` does, which is why every `gh` call in this file worked and the
# `git push` at the end of a landed issue did not: with no credential helper configured, an HTTPS
# push asks for a username, there is no terminal to ask, and it dies with 128. Measured in the image
# with a valid token in the environment: `gh auth status` ok, `git credential fill` fatal, `git push
# --dry-run` 128. It stayed hidden because every run so far set NO_PUSH=1 — the shape of bug that
# waits for the run you most want to succeed, since the first pushing run would have aborted at its
# first landed issue on the deliberate `else` that stops a batch when a push fails.
#
# `!gh auth git-credential` and not `store`: the helper shells out to gh, which reads the token from
# its own environment each time, so nothing is written to disk. A `store` helper would leave the PAT
# in ~/.git-credentials inside the container — a file every implementer can read, and whose absence
# deploy/README.md documents as a property this design relies on.
#
# Passed per invocation rather than written with `git config`. `--global` would leave a credential
# helper in the ~/.gitconfig of anyone who ran the loop outside Docker, which the README describes as
# a supported way to run it, and `--local` would do the same to the target repository's .git/config.
# Neither is ours to modify, and a flag at the call site is also where a reader will look for it.
#
# None of this weakens the `env -u GH_TOKEN` around model invocations. The helper is a way to *reach*
# the token, not a copy of it: with GH_TOKEN stripped, gh cannot authenticate, the helper returns
# nothing, and an implementer still cannot push.
GIT_CRED=(-c 'credential.https://github.com.helper=!gh auth git-credential')

# Proven at preflight, because the alternative is discovering it after an issue's worth of spend. Only
# when this run intends to push, and only for a github.com origin — the helper is scoped to that host,
# so anywhere else this check would fail for a reason it is not equipped to fix.
#
# A here-string, not `printf ... | git credential fill`: that pipeline is the exact shape that made
# gate.sh report an empty test suite for a fortnight. See the comment on that fix.
case "$(git remote get-url origin)" in
  *github.com*)
    if [ -z "$NO_PUSH" ]; then
      GIT_TERMINAL_PROMPT=0 git "${GIT_CRED[@]}" credential fill \
          <<<$'protocol=https\nhost=github.com\n' >/dev/null 2>&1 \
        || die "git cannot get a credential for github.com, so every push this run makes would fail with 'could not read Username'. gh being authenticated is not the same thing: gh reads GH_TOKEN and git does not. Set NO_PUSH=1 to run without pushing."
    fi
    ;;
esac

# Prune the landed list of issues that are no longer open. An entry there means only "work exists for
# this issue which the issue itself does not yet reflect", and a closed issue reflects it — so the
# entry has served its purpose and keeping it is actively harmful. Reopening an issue is how a human
# says the work was not good enough, and a permanent skip entry would make that reopened issue
# invisible to the queue for ever, silently, with the run reporting an empty backlog.
#
# Left alone otherwise: an entry for an issue that is still open is the whole point of the file, and it
# is what stops a NO_PUSH run implementing the same issue on every iteration.
#
# Both awks below read the reference file with getline rather than the usual NR==FNR two-file trick,
# and that is not a style choice. NR==FNR is true for *every* line of the second file when the first
# one is empty, so the "which entries went" version reported nothing precisely when everything was
# pruned — the file was emptied correctly and silently. An empty reference file is not an edge case
# here: it is a queue with no open issues left, which is where this loop is trying to get to.
if [ -s "$LANDED" ]; then
  open_list="$LOGS/.landed-prune.$$"
  if gh issue list --state open --limit 300 --json number --jq '.[].number' > "$open_list" 2>/dev/null; then
    awk -v openfile="$open_list" \
        'BEGIN { while ((getline l < openfile) > 0) open[l] } ($0 in open)' \
        "$LANDED" > "$LANDED.tmp"
    removed=$(awk -v keepfile="$LANDED.tmp" \
        'BEGIN { while ((getline l < keepfile) > 0) keep[l] } !($0 in keep)' \
        "$LANDED" | tr '\n' ' ')
    mv "$LANDED.tmp" "$LANDED"
    [ -n "$removed" ] && say "landed list: pruned issue(s) no longer open: $removed"
  fi
  rm -f "$open_list"
fi

say "harness $HARNESS -> repo $REPO ($(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD))"
say "model $MODEL (fallback $FALLBACK_MODEL), $MAX_ROUNDS rounds/issue, $TIMEOUT per invocation, $([ "$MAX_SPEND" = 0 ] && echo "no spend cap" || echo "\$$MAX_SPEND spend cap")"
say "queue: $(gh issue list --state open --limit 300 --json number --jq 'length') open issue(s)"

# PREFLIGHT_ONLY=1 verifies the wiring — auth, tools, repo, remote, queue — and spends nothing.
# Run this against a new container before trusting it with a night.
if [ -n "${PREFLIGHT_ONLY:-}" ]; then
  say "PREFLIGHT_ONLY set — everything checks out, exiting without doing any work"
  exit 0
fi

# --- the two kinds of invocation -------------------------------------------------

# work <tag>   : full tool access, edits the repo. Prompt on stdin.
#
# GH_TOKEN is stripped from the environment. The prompts tell the implementer not to push or
# close issues, but a prompt is a request; with no token and no ~/.config/gh in the image,
# `gh` cannot authenticate and `git push` over HTTPS has no credential — so it is enforced.
# Only the harness holds the token. AWS credentials stay: Bedrock inference needs them.
work() {
  local tag="$1"
  # The +expansion guard is not decoration: bash 3.2, which is what macOS ships, treats
  # "${arr[@]}" on an empty array as an unbound variable under `set -u`.
  env -u GH_TOKEN -u GITHUB_TOKEN \
  ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p \
    --model "$MODEL" \
    --fallback-model "$FALLBACK_MODEL" \
    --output-format json \
    --no-session-persistence \
    --dangerously-skip-permissions \
    --debug-file "$LOGS/$tag.debug.log" \
    > "$LOGS/$tag.json" 2>>"$LOGS/run.log"
  local rc=$?
  jq -r '.result // "(no result)"' "$LOGS/$tag.json" > "$LOGS/$tag.txt" 2>/dev/null
  say "  $tag: rc=$rc cost=\$$(jq -r '.total_cost_usd // 0' "$LOGS/$tag.json" 2>/dev/null) turns=$(jq -r '.num_turns // 0' "$LOGS/$tag.json" 2>/dev/null) reason=$(jq -r '.terminal_reason // "?"' "$LOGS/$tag.json" 2>/dev/null)"
  return $rc
}

# critic <tag> <verdict-out> : read-only by tool restriction, returns validated JSON. Prompt on stdin.
# Fails closed — a crashed or truncated critic is a FAIL, never a silent PASS.
critic() {
  local tag="$1" out="$2"
  # The +expansion guard is not decoration: bash 3.2, which is what macOS ships, treats
  # "${arr[@]}" on an empty array as an unbound variable under `set -u`.
  env -u GH_TOKEN -u GITHUB_TOKEN \
  ${TIMEOUT_CMD[@]+"${TIMEOUT_CMD[@]}"} claude -p \
    --model "$MODEL" \
    --fallback-model "$FALLBACK_MODEL" \
    --output-format json \
    --json-schema "$SCHEMA" \
    --tools "Read,Grep,Glob" \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --debug-file "$LOGS/$tag.debug.log" \
    > "$LOGS/$tag.json" 2>>"$LOGS/run.log"

  if ! jq -e '.structured_output.verdict' "$LOGS/$tag.json" >/dev/null 2>&1; then
    say "  $tag: no structured output — failing closed"
    printf '{"verdict":"FAIL","findings":[{"file":"-","problem":"The %s invocation did not return a verdict (crash or timeout).","fix":"Re-run; if it repeats, the diff is probably too large to review in one pass."}]}\n' "$tag" > "$out"
    return 0
  fi
  jq '.structured_output' "$LOGS/$tag.json" > "$out"
  say "  $tag: $(jq -r .verdict "$out") ($(jq -r '.findings|length' "$out") findings) cost=\$$(jq -r '.total_cost_usd // 0' "$LOGS/$tag.json")"
}

# critic_name <role> : what the fixer sees the findings attributed to
critic_name() {
  case "$1" in
    review) printf 'correctness reviewer' ;;
    idiom)  printf 'idiom critic' ;;
    tests)  printf 'test critic' ;;
    *)      printf '%s' "$1" ;;
  esac
}

# findings_text <verdict-json...> : the findings as a flat list for the fixer
findings_text() {
  jq -r '.findings[] | "- \(.file): \(.problem)\n  FIX: \(.fix)"' "$@"
}

# --- the loop --------------------------------------------------------------------

# The line everything this run spends is measured against. Touched here rather than at the top of the
# script so PREFLIGHT_ONLY, which spends nothing, does not disturb the marker a real run left behind.
touch "$RUN_MARKER"

done_count=0
attempted=0
# The issues *this* run touched, which is not the same as the issues the log directory holds
# artifacts for: a long-lived LOGS accumulates every batch ever run into it. RETRO=1 reviews this
# batch, so it needs the list rather than the count.
attempted_issues=()
consecutive_abandons=0
retried=0
retry_landed=0
# Issues abandoned in the main pass, as "<number> <base>", to re-attempt once the queue has moved on.
# The base is recorded with the number because it is what makes the re-attempt worth paying for: see
# the retry phase below.
retry_queue=()
retry_count=0
retry_index=0
phase=main
while :; do
  # Issues *attempted*, not issues landed. Gating on the landed count sounds equivalent and is not:
  # every abandonment buys the run another issue, so a bounded batch quietly outgrows the range the
  # operator scoped it to (12 issues over #14-#25, one abandonment, and it reaches for #26), and
  # MAX_ISSUES=1 stops being a smoke test at exactly the moment its one issue gives up — which is
  # when you want to read the logs, not spend again. What this knob bounds is what the run touches
  # and what it costs, and an abandonment costs the most of all: an implement, MAX_ROUNDS of fixes,
  # and every critic in between.
  #
  # It bounds the main pass rather than the run, because a re-attempt of an abandoned issue adds
  # nothing to the set of issues the operator scoped: #21 re-attempted is still #21. Ending the main
  # pass here instead of ending the run is what lets a bounded batch — which is how this is actually
  # run, MAX_ISSUES=12 over #14-#25 — retry at all. Bounding the run instead means the retry phase is
  # unreachable in every batch that fills its bound, which is every batch that goes well.
  if [ "$phase" = main ] && [ "$MAX_ISSUES" -gt 0 ] && [ "$attempted" -ge "$MAX_ISSUES" ]; then
    say "hit MAX_ISSUES=$MAX_ISSUES"
    phase=retry
  fi

  # The spend cap. Checked here, between issues, and deliberately nowhere else: an issue killed
  # part-way through has an unjudged diff in the working tree and no branch to its name, which is the
  # one outcome the loop is built to never produce. So the cap is a bound on what the run *starts*,
  # not on what it finishes — overshoot by up to one issue is the price of never abandoning work
  # mid-flight, and an issue costs at most an implement, MAX_ROUNDS fixes and their critics.
  #
  # It applies in the retry phase too. A re-attempt is money like any other.
  if [ "$attempted" -gt 0 ] && [ "$MAX_SPEND" != 0 ]; then
    spent="$(spend_this_run)"
    if awk -v s="$spent" -v m="$MAX_SPEND" 'BEGIN { exit !(s >= m) }'; then
      say "hit MAX_SPEND=\$$MAX_SPEND (\$$spent spent over $attempted issue(s)) — stopping here rather than starting another issue"
      break
    fi
  fi

  # Two circuit breakers, both aimed at the same failure: the environment breaks partway through a
  # long queue and the loop keeps going, abandoning every remaining issue for a reason that has
  # nothing to do with the issue. Each abandonment costs an implement invocation, MAX_ROUNDS fix
  # invocations and every critic in between, and leaves a needs-human label on work nobody has
  # looked at. Stopping is recoverable; a queue of spurious abandonments is not.
  if [ "$attempted" -gt 0 ] && [ "${CLAUDE_CODE_USE_BEDROCK:-}" = "1" ]; then
    # Credentials are the likeliest thing to go: a role session expires mid-run, every invocation
    # after it fails, and every critic fails closed into a FAIL. One free API call rules it out.
    aws sts get-caller-identity >/dev/null 2>&1 \
      || die "AWS credentials stopped resolving after $attempted issue(s) — stopping before the rest of the queue is abandoned over it. Refresh them and run again; the queue picks up from the issues still open."
  fi
  if [ "$MAX_CONSECUTIVE_ABANDONS" -gt 0 ] && [ "$consecutive_abandons" -ge "$MAX_CONSECUTIVE_ABANDONS" ]; then
    die "$consecutive_abandons issue(s) abandoned in a row — stopping. That is far more often a broken environment (expired credentials, a wedged toolchain, a model outage, a missing dependency every issue needs) than several independently hard issues. The work is parked on branches and the numbers are in $(basename "$SKIPPED"); set MAX_CONSECUTIVE_ABANDONS=0 to run through them anyway."
  fi

  # The queue: open issues, lowest number first (the issues are numbered in dependency
  # order), minus the ones this run gave up on and the ones it landed without closing.
  #
  # That second exclusion is what makes NO_PUSH work for more than one issue. Normally an issue
  # leaves the queue by being closed, so the queue needs no memory of success; under NO_PUSH
  # nothing remote changes, so a landed issue is indistinguishable from an untouched one and the
  # next iteration hands the implementer the issue it has just finished — which then produces an
  # empty diff and gets abandoned. Both lists persist in LOGS on purpose: re-running after a
  # NO_PUSH night continues the queue instead of redoing the commits already on your local main.
  # (the lists are read in BEGIN rather than as leading file arguments: the NR==FNR idiom
  #  silently swallows the whole queue when the first file is empty)
  if [ "$phase" = main ]; then
    N=$(gh issue list --state open --limit 300 --json number --jq '[.[].number] | sort | .[]' \
        | awk -v sf="$SKIPPED" -v lf="$LANDED" \
            'BEGIN { while ((getline l < sf) > 0) skip[l]
                     while ((getline l < lf) > 0) skip[l] } !($0 in skip)' \
        | head -1)
    [ -n "$N" ] || { say "no open issues left in the main pass"; phase=retry; }
  fi

  # The retry phase. The backlog is numbered in dependency order and the loop resets to main and moves
  # on when an issue is abandoned, so an abandonment leaves a *hole in the middle of an ordered queue*
  # while everything after it keeps landing on top. That is not hypothetical: #21 (an unimplemented
  # Files API terminal) abandoned, #22-#26 landed over it, and the tree ended the batch with five
  # commits of kernel under a gap that the issue itself had been the prerequisite for.
  #
  # So an abandoned issue gets exactly one more attempt, at the end, against the tree the batch
  # actually finished on. Three properties make that cheap rather than a licence to spend twice:
  #
  #   - Only issues *this run* abandoned. An entry already in the skipped list is one a human parked,
  #     or one a previous run gave up on, and re-attempting it is that human's call to make.
  #   - Only when the base moved. If nothing landed after the issue, the re-attempt runs the same
  #     prompts over the same tree and fails the same way for the same reason — so it is skipped, and
  #     the pathological case where every issue abandons therefore retries nothing and costs nothing.
  #   - Once. A retried issue that abandons again is not queued a third time.
  #
  # It does not run at all after the consecutive-abandon breaker: that path calls die(), because a
  # broken environment is the one situation where spending again is certainly wrong.
  if [ "$phase" = retry ]; then
    N=""
    while [ -n "$RETRY_ABANDONED" ] && [ "$retry_index" -lt "$retry_count" ]; do
      entry="${retry_queue[$retry_index]}"
      retry_index=$((retry_index + 1))
      candidate="${entry%% *}"; candidate_base="${entry##* }"
      if [ "$(git rev-parse HEAD)" = "$candidate_base" ]; then
        say "retry: leaving #$candidate alone — nothing landed after it, so a re-attempt would run against the same tree it already failed on"
        continue
      fi
      # A human may have closed it, or done the work by hand, in the hours since it was abandoned.
      # Separators normalised in the shell rather than by the --jq expression, and not piped into
      # `grep -q`: grep exits at the first match, gh takes SIGPIPE, and under pipefail the pipeline
      # reports 141 — which would read here as "not open" and silently skip every retry.
      open_now=$(gh issue list --state open --limit 300 --json number --jq '.[].number' | tr '\n' ' ')
      case " $open_now " in
        *" $candidate "*) ;;
        *) say "retry: leaving #$candidate alone — it is no longer open"; continue ;;
      esac
      N="$candidate"
      break
    done
    [ -n "$N" ] || { say "nothing further to attempt — done"; break; }
    attempt=2
    # The artifacts of the two attempts must not share filenames: the first attempt's gate output,
    # diffs and verdicts are the evidence a human reads to decide whether the retry was even the right
    # idea, and overwriting them in place would destroy exactly that.
    TAG="$N-retry"
    retried=$((retried + 1))
  else
    attempt=1
    TAG="$N"
  fi

  TITLE=$(gh issue view "$N" --json title --jq .title)
  BASE=$(git rev-parse HEAD)
  # Body first, then any comments. NOT `gh issue view --comments`, which shows the comments
  # *instead of* the body and so silently yields an empty file on an uncommented issue.
  gh issue view "$N" --json title,body,comments --jq \
    '"# \(.title)\n\n\(.body)\n" + (if (.comments | length) > 0
       then "\n## Comments\n" + ([.comments[] | "\n**\(.author.login):**\n\(.body)"] | join("\n"))
       else "" end)' > "$LOGS/issue-$N.md"
  body_bytes=$(wc -c < "$LOGS/issue-$N.md" | tr -d ' ')
  if [ "$attempt" -gt 1 ]; then
    say "=== issue #$N RE-ATTEMPT: $TITLE (base $(git rev-parse --short "$BASE"), was abandoned on $(git rev-parse --short "$candidate_base")) ==="
  else
    say "=== issue #$N: $TITLE (base $(git rev-parse --short "$BASE"), ${body_bytes}b of description) ==="
  fi
  [ "$body_bytes" -gt 80 ] || say "  WARNING: issue #$N has almost no description — the implementer is working from the title alone"

  # A fresh implementer working from the issue and the tree, with one thing carried across from an
  # attempt that was abandoned: the findings that were still outstanding when it was parked.
  #
  # Not its diff, and not its NOTES.md. Those would make this a fourth fix round rather than a second
  # attempt, resuming the round that had already stopped converging — and starting clean is what
  # produced a diff that passed in two rounds when #21 and #26 were re-attempted. The findings are
  # different: they are the paid-for account of *why* the first attempt failed, they were sitting
  # unread on disk while $40 went on re-deriving the same work, and as constraints rather than a
  # worklist they cost nothing to honour.
  carry="$LOGS/$TAG-carryover.md"
  rm -f "$carry"
  if [ "$attempt" -gt 1 ] || [ -n "$CARRY_FINDINGS" ]; then
    # The last round that found anything, counting down: the final round of an abandoned issue is
    # sometimes a gate failure with no verdicts at all, and the round before it is then the one
    # holding the reasons.
    for r in $(seq "$((MAX_ROUNDS + 1))" -1 1); do
      for role in "${CRITICS[@]}"; do
        v="$LOGS/$N-$role-$r.verdict.json"
        [ -f "$v" ] || continue
        [ "$(jq -r '.findings | length' "$v" 2>/dev/null)" -gt 0 ] 2>/dev/null || continue
        if [ ! -s "$carry" ]; then
          {
            echo "## Outstanding findings from an earlier attempt at this issue"
            echo
            echo "A previous attempt was reviewed, could not be got past review, and is parked on the"
            echo "branch \`abandoned/issue-$N\`. It is **not** in the tree you are working on, and you are"
            echo "not resuming it: implement the issue as you see it now, against a tree that has moved."
            echo "These are the findings that were still outstanding when it was abandoned. You are free"
            echo "to solve the issue a different way; you are not free to reproduce these."
            echo
          } > "$carry"
        fi
        { echo "From the $(critic_name "$role"), round $r:"; findings_text "$v"; echo; } >> "$carry"
      done
      [ -s "$carry" ] && break
    done
    [ -s "$carry" ] && say "  carrying $(grep -c '^- ' "$carry" | tr -d ' ') outstanding finding(s) from the abandoned attempt into the re-implementation"
  fi
  { cat "$HARNESS/prompts/implement.md"
    echo "## Issue #$N: $TITLE"; echo
    cat "$LOGS/issue-$N.md"
    [ -s "$carry" ] && { echo; cat "$carry"; }
  } | work "$TAG-implement"

  approved=0
  # Why the round loop stopped, when it stopped for a reason other than running out of rounds. It
  # exists because the abandon message is the only account of the issue a human reads in the morning,
  # and "ABANDONED after 3 rounds" is a false one for an issue that broke out of round 1 — it sends
  # the reader looking for three verdicts that were never written, instead of at an implementer that
  # returned without touching the tree.
  abandon_reason=""
  verdicts=""     # the last round's votes, for the branch message when the issue is abandoned
  # MAX_ROUNDS is a bound on *fixes*, and the loop runs one more round than that so its last act is
  # always a verdict rather than a fix. Bounding the rounds themselves instead means the final round
  # votes, FAILs, pays a fixer to address the findings — and then abandons the issue without ever
  # gating or reviewing what that fixer did. The first long batch lost both of its abandonments that
  # way: #21 and #26, $38.64 of a $161.59 batch, both ending in a fix that completed, reported a
  # green gate and addressed the only outstanding finding, parked on a branch with nobody having
  # looked at it. The extra round costs one critic trio, and only on issues headed for abandonment —
  # an issue that lands has already broken out of the loop on unanimous PASS.
  #
  # All the critics vote in that final round, not just the ones that FAILed. Re-running only the
  # dissenters is cheaper and unsound: it would assemble unanimity out of verdicts on two different
  # diffs, which is exactly the failure the round structure exists to prevent.
  final_round=$((MAX_ROUNDS + 1))
  for round in $(seq 1 "$final_round"); do

    # 1. Deterministic gate. Never spend model tokens reviewing code that does not build.
    # BASE lets the gate notice a deleted test; LOGS keeps the coverage profile out of the repo.
    if ! REPO="$REPO" BASE="$BASE" LOGS="$LOGS" "$HARNESS/gate.sh" > "$LOGS/$TAG-gate-$round.txt" 2>&1; then
      say "  round $round: gate failed"
      if [ "$round" -eq "$final_round" ]; then
        abandon_reason="the gate was still failing after $MAX_ROUNDS round(s) of fixes"
        break
      fi
      { cat "$HARNESS/prompts/fix.md"
        echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
        echo "## Failing checks"; echo '```'; cat "$LOGS/$TAG-gate-$round.txt"; echo '```'
      } | work "$TAG-fix-$round"
      continue
    fi
    say "  round $round: gate clean"

    # 2. The diff the critics judge. Staged so that newly created files are included.
    git add -A
    git diff --cached "$BASE" > "$LOGS/$TAG-diff-$round.patch"
    if [ ! -s "$LOGS/$TAG-diff-$round.patch" ]; then
      say "  round $round: empty diff — the implementer changed nothing"
      abandon_reason="the implementer changed nothing on round $round, so there was nothing to review"
      break
    fi
    if [ "$(wc -c < "$LOGS/$TAG-diff-$round.patch")" -gt "$MAX_DIFF_BYTES" ]; then
      say "  round $round: WARNING diff exceeds $MAX_DIFF_BYTES bytes — critics see a truncated diff"
    fi

    # 3. Every critic, concurrently, on the same diff.
    #
    # A role named in DOUBLE_CRITICS runs *twice* in round 1 and its findings are unioned. This is
    # aimed at one measured failure, not at thoroughness in general: three times now the test critic
    # has reported one of two findings that were both in front of it, and the second one has cost a
    # whole round each time — on #26 the round-2 finding was in a test file that is byte-identical in
    # the round-1 and round-2 diffs, so it was fully visible in round 1. Two rounds of prose in
    # tests.md have not fixed it, which is what makes it a structural problem rather than a wording one.
    #
    # Round 1 only, because that is where a missed finding costs a round; and the two passes are given
    # different framings rather than being identical, because two identical prompts are the weakest
    # available way to spend twice — the second pass is told to sweep exhaustively and report every
    # instance, which is precisely the lens the misses have been in.
    for role in "${CRITICS[@]}"; do
      ctags="$TAG-$role-$round"
      case " $DOUBLE_CRITICS " in
        *" $role "*) [ "$round" -eq 1 ] && ctags="$TAG-$role-${round}a $TAG-$role-${round}b" ;;
      esac
      for ctag in $ctags; do
        { cat "$HARNESS/prompts/$role.md"
          case "$ctag" in
            *b) cat <<'SWEEP'

## For this pass specifically

Another instance of this review is running on this same diff, concurrently, and will report whatever
it considers most important. Your job here is the opposite one: completeness. Go through the changed
files one at a time, and for each, name every instance of a problem you find rather than the worst
one. A finding you leave out because it is smaller than another one is a finding nobody makes: the
next round will not look at this diff again.
SWEEP
              ;;
          esac
          echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
          echo "## What the implementer says it did"; echo; cat "$LOGS/$TAG-implement.txt"; echo
          echo "## The diff under review (since $BASE)"; echo '```diff'
          head -c "$MAX_DIFF_BYTES" "$LOGS/$TAG-diff-$round.patch"; echo '```'
        } | critic "$ctag" "$LOGS/$ctag.verdict.json" &
      done
    done
    wait

    # The union, written to the path the rest of the loop reads, so nothing downstream — the unanimity
    # check, the fixer's findings sections, the retrospective's round table — needs to know a role ran
    # twice. FAIL if either pass failed: a critic that fails closed on a crash still has to hold the
    # issue back, and two passes must not be a way for one of them to be outvoted.
    for role in "${CRITICS[@]}"; do
      pa="$LOGS/$TAG-$role-${round}a.verdict.json"; pb="$LOGS/$TAG-$role-${round}b.verdict.json"
      [ -f "$pa" ] && [ -f "$pb" ] || continue
      jq -s '{ verdict:  ([.[].verdict] | map(. == "FAIL") | any | if . then "FAIL" else "PASS" end),
               findings: ([.[].findings] | add | unique_by(.file + " " + .problem)) }' \
        "$pa" "$pb" > "$LOGS/$TAG-$role-$round.verdict.json"
      say "  $TAG-$role-$round: two passes unioned -> $(jq -r .verdict "$LOGS/$TAG-$role-$round.verdict.json") ($(jq -r '.findings|length' "$LOGS/$TAG-$role-$round.verdict.json") finding(s) from $(jq -r '.findings|length' "$pa")+$(jq -r '.findings|length' "$pb"))"
    done

    # Unanimity, and it has to be unanimous the hard way: `critic` fails closed, so a crashed or
    # truncated invocation is a FAIL and holds the issue back rather than waving it through.
    all_pass=1
    verdicts=""
    for role in "${CRITICS[@]}"; do
      v=$(jq -r '.verdict' "$LOGS/$TAG-$role-$round.verdict.json")
      verdicts="$verdicts $role=$v"
      [ "$v" = PASS ] || all_pass=0
    done
    if [ "$all_pass" = 1 ]; then
      approved=1
      say "  round $round: all ${#CRITICS[@]} critics PASS"
      break
    fi

    # 4. Fix, then round again. Only the critics that actually found something get a section: an
    # empty heading reads to the fixer as a reviewer with nothing to say, and this prompt's whole
    # job is to be actionable.
    if [ "$round" -eq "$final_round" ]; then
      say "  round $round:$verdicts — no fix after the last verdict, so this is where it stops"
      abandon_reason="no unanimous PASS after $MAX_ROUNDS round(s) of fixes, the last of them reviewed"
      break
    fi
    say "  round $round:$verdicts — sending findings back"
    { cat "$HARNESS/prompts/fix.md"
      echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
      for role in "${CRITICS[@]}"; do
        [ "$(jq -r '.findings | length' "$LOGS/$TAG-$role-$round.verdict.json")" -gt 0 ] || continue
        echo "## Blocking findings — $(critic_name "$role")"; echo
        findings_text "$LOGS/$TAG-$role-$round.verdict.json"; echo
      done
    } | work "$TAG-fix-$round"
  done

  # --- land it, or hand it to a human ---
  #
  # An issue is resolved only when the work implementing it is on origin. Nothing below closes an
  # issue on any weaker basis than that: not an approval with nothing to show for it, and not a
  # commit that never left this machine.
  git add -A
  if [ "$approved" = 1 ] && git diff --cached --quiet "$BASE"; then
    # Unanimous approval of an empty tree. It should be unreachable — an empty diff breaks the round
    # loop before any critic runs — so if it happens the interesting thing is why, and closing the
    # issue would destroy the evidence and the issue with it.
    say "#$N WARNING: all critics approved but the tree matches base. Leaving the issue OPEN and skipping it: an issue is not resolved by an approval with no commit behind it."
    record_skipped "$N"
    consecutive_abandons=$((consecutive_abandons + 1))
  elif [ "$approved" = 1 ]; then
    git commit -q -m "$TITLE" -m "Closes #$N" -m "Implemented by the ArchUnitDev loop." \
      || die "commit failed for #$N"
    landed_as=$(git rev-parse --short HEAD)
    # An issue that landed does not need a human, whatever an earlier attempt of it concluded. Left in
    # place, the entry would outlive its reason twice over: the final count would report the issue as
    # abandoned, and the retrospective labels an outcome from this file, so a landed issue would be
    # written up as ABANDONED with its own passing verdicts sitting next to the claim.
    if [ "$attempt" -gt 1 ]; then
      forget_skipped "$N"
      retry_landed=$((retry_landed + 1))
      say "#$N landed on the re-attempt — the first attempt's work is still on abandoned/issue-$N"
    fi
    if [ -n "$NO_PUSH" ]; then
      # Recorded so the queue moves on: see the comment on LANDED above.
      echo "$N" >> "$LANDED"
      say "#$N committed locally as $landed_as; NO_PUSH set, so not pushing and leaving the issue open (recorded in $(basename "$LANDED"))"
      say "#$N DONE"
      done_count=$((done_count + 1))
      consecutive_abandons=0
    elif git "${GIT_CRED[@]}" push -q origin HEAD; then
      # The commit message closes the issue by itself once it is on the default branch; this is the
      # belt to that braces, and it is also what leaves the review trail on the issue.
      say "#$N pushed as $landed_as"
      gh issue close "$N" --comment "Implemented by the ArchUnitDev loop; all ${#CRITICS[@]} reviewers passed." >/dev/null 2>&1 \
        || say "  (#$N was already closed by the commit message, or could not be closed — the work is on origin either way)"
      say "#$N DONE"
      done_count=$((done_count + 1))
      consecutive_abandons=0
    else
      # The work is committed locally and reachable, so nothing is lost — but it is not on origin,
      # so the issue is not resolved and must not be closed. Stopping rather than carrying on: every
      # later push fails the same way, and a run that closes issues while nothing reaches origin is
      # the worst outcome available.
      die "push failed for #$N — the commit is local only ($landed_as), so the issue stays OPEN. Nothing after this would reach origin either. Fix the remote and run again: the queue resumes from the issues still open."
    fi
  else
    # Abandon: keep the work on a branch so nothing is lost, reset main, move on.
    # Nor does this line claim the work was parked: there may be none to park, and the branch it
    # would name is reported below, when there is.
    say "#$N ABANDONED — ${abandon_reason:-no unanimous PASS in $MAX_ROUNDS rounds} — leaving the issue open"
    if ! git diff --cached --quiet "$BASE"; then
      branch="abandoned/issue-$N"
      # A second attempt gets its own ref. `git branch -f` on the same name would move the first
      # attempt's branch to the second attempt's tip, and since the first attempt's commit is by then
      # unreachable from anything, the work a human was explicitly left would be gone.
      [ "$attempt" -gt 1 ] && branch="abandoned/issue-$N-attempt-$attempt"
      # The reason and the final verdicts go in the message, because this branch is the handoff: the
      # tip has been gated and judged, so whoever picks it up should be told what the last word on it
      # actually was rather than having to go back to the log directory for it.
      git commit -q -m "WIP #$N: $TITLE" \
        -m "Abandoned by the ArchUnitDev loop: ${abandon_reason:-no unanimous PASS}.${verdicts:+ Final round:$verdicts.} Needs a human."
      git branch -f "$branch" HEAD
      [ -n "$NO_PUSH" ] || git "${GIT_CRED[@]}" push -q origin "$branch" || say "WARNING: could not push $branch"
      git reset -q --hard "$BASE"
      say "#$N work parked on branch $branch; $REPO reset to $(git rev-parse --short "$BASE")"
    fi
    if [ -z "$NO_PUSH" ]; then
      gh issue edit "$N" --add-label needs-human >/dev/null 2>&1 \
        || gh issue comment "$N" --body "The ArchUnitDev loop could not get this past review in $MAX_ROUNDS rounds. Needs a human." >/dev/null 2>&1 \
        || say "WARNING: could not annotate #$N"
    fi
    record_skipped "$N"
    consecutive_abandons=$((consecutive_abandons + 1))
    # Queued for one more attempt at the end of the run, against whatever the batch lands over it. The
    # base is recorded here rather than looked up later because by then HEAD has moved: the question
    # the retry phase asks is whether it moved *since this issue failed*, and this is the only place
    # that commit is still known.
    if [ "$phase" = main ] && [ -n "$RETRY_ABANDONED" ]; then
      retry_queue+=("$N $BASE")
      retry_count=$((retry_count + 1))
    fi
  fi
  attempted=$((attempted + 1))
  # Narrated at every issue boundary whether or not there is a cap, because this is the number you
  # want when you come back to a night's log and the question is "what did that cost me": the
  # end-of-run total tells you afterwards, and this tells you while it is still running.
  say "spend so far this run: \$$(spend_this_run) over $attempted issue(s)"
  # Once per issue, not once per attempt: this list is what the retrospective is given as the batch,
  # and a duplicate number would have it write the same issue up twice.
  case " ${attempted_issues[*]-} " in
    *" $N "*) ;;
    *) attempted_issues+=("$N") ;;
  esac
done

say "run finished: $done_count issue(s) landed, $(abandoned_this_run) abandoned"
# What is in the skipped list but was not this run's doing. Worth a line of its own rather than being
# folded into the count above: it is the difference between "this batch failed five times" and "five
# issues are waiting for a reason that has nothing to do with tonight".
if [ "$(other_skipped)" -gt 0 ]; then
  say "  ($(other_skipped) further issue(s) in $(basename "$SKIPPED") from earlier batches or held back by hand: $(other_skipped_list))"
fi
[ "$retried" -gt 0 ] && say "re-attempted $retried abandoned issue(s) on the batch's final tree: $retry_landed landed, $((retried - retry_landed)) still need a human"
# This run's spend, and the log directory's, separately. They differ whenever LOGS has been used
# before, which is the normal case here — and the single glob total used to be reported as "total
# spend", which read as this batch's cost and quietly grew by every earlier batch.
say "spend: \$$(spend_this_run) this run; \$$(spend_all_time) in $(basename "$LOGS") all told"

# The retrospective on the batch — the loop reviewing itself rather than the code. Off by default:
# it costs a model invocation and it is only worth anything once several issues have been through.
#
# Last, and non-fatal, deliberately. Everything above has already landed, so a retrospective that
# crashes must not turn a successful night into a failed one — and it must not be able to change the
# exit status a caller reads to decide whether the batch worked.
if [ -n "${RETRO:-}" ] && [ "${#attempted_issues[@]}" -gt 0 ]; then
  REPO="$REPO" LOGS="$LOGS" MAX_ROUNDS="$MAX_ROUNDS" MODEL="$MODEL" \
    FALLBACK_MODEL="$FALLBACK_MODEL" TIMEOUT="$TIMEOUT" \
    "$HARNESS/retro.sh" "${attempted_issues[@]}" \
    || say "retro: failed — the batch above is unaffected"
fi

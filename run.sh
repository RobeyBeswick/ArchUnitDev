#!/usr/bin/env bash
#
# ArchUnitDev — an unattended implement / review / fix loop.
#
# For each open issue in the target repo, lowest number first:
#   implement  ->  [ deterministic gate  ->  reviewer + idiom critic  ->  fix ] x MAX_ROUNDS
#              ->  commit, push, close the issue
#
# State lives in git and in the GitHub issues. There is no database and no resume logic:
# the next issue is always "the lowest-numbered open one", so a killed run is restarted
# by running this script again.
#
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:-/work/repo}"
LOGS="${LOGS:-$HARNESS/logs}"

MAX_ROUNDS="${MAX_ROUNDS:-3}"       # review/fix rounds before an issue is abandoned
MAX_ISSUES="${MAX_ISSUES:-0}"       # 0 = run until the queue is empty
BUDGET_USD="${BUDGET_USD:-5}"       # per invocation, not per issue
TIMEOUT="${TIMEOUT:-30m}"           # wall clock per invocation
# Bedrock model IDs, not the "opus"/"sonnet" aliases: the aliases only resolve via
# ANTHROPIC_DEFAULT_*_MODEL, which lives in the host's ~/.claude/settings.json and is
# deliberately not carried into the container.
MODEL="${MODEL:-global.anthropic.claude-opus-5}"
FALLBACK_MODEL="${FALLBACK_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
MAX_DIFF_BYTES="${MAX_DIFF_BYTES:-400000}"

SCHEMA="$(cat "$HARNESS/schema/verdict.json")"
SKIPPED="$LOGS/skipped"

mkdir -p "$LOGS"
touch "$SKIPPED"

say() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOGS/run.log"; }
die() { say "FATAL: $*"; exit 1; }

# --- preflight -------------------------------------------------------------------
# Every check here is something that otherwise fails silently or halfway through the night.

[ "$(id -u)" -ne 0 ] || die "refusing to run as root: Claude Code blocks --dangerously-skip-permissions for the root user. Run the container as a non-root user."
command -v claude >/dev/null || die "claude not on PATH"
command -v gh     >/dev/null || die "gh not on PATH"
command -v jq     >/dev/null || die "jq not on PATH"
command -v go     >/dev/null || say "WARNING: go not on PATH — the build and test gate will be skipped"
[ -d "$REPO/.git" ] || die "$REPO is not a git repository (mount the target repo there, or set REPO)"

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
  if [ -n "${AWS_SESSION_TOKEN:-}" ] && [ -z "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]; then
    say "WARNING: using static temporary credentials from the environment. These expire and will NOT refresh — fine for a smoke test, not for a full overnight run. Prefer an EC2 instance profile."
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

say "harness $HARNESS -> repo $REPO ($(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD))"
say "model $MODEL (fallback $FALLBACK_MODEL), $MAX_ROUNDS rounds/issue, \$$BUDGET_USD and $TIMEOUT per invocation"
say "queue: $(gh issue list --state open --limit 300 --json number --jq 'length') open issue(s)"

# PREFLIGHT_ONLY=1 verifies the wiring — auth, tools, repo, remote, queue — and spends nothing.
# Run this against a new container before trusting it with a night.
if [ -n "${PREFLIGHT_ONLY:-}" ]; then
  say "PREFLIGHT_ONLY set — everything checks out, exiting without doing any work"
  exit 0
fi

# --- the two kinds of invocation -------------------------------------------------

# work <tag>   : full tool access, edits the repo. Prompt on stdin.
work() {
  local tag="$1"
  timeout "$TIMEOUT" claude -p \
    --model "$MODEL" \
    --fallback-model "$FALLBACK_MODEL" \
    --output-format json \
    --max-budget-usd "$BUDGET_USD" \
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
  timeout "$TIMEOUT" claude -p \
    --model "$MODEL" \
    --fallback-model "$FALLBACK_MODEL" \
    --output-format json \
    --json-schema "$SCHEMA" \
    --tools "Read,Grep,Glob" \
    --dangerously-skip-permissions \
    --max-budget-usd "$BUDGET_USD" \
    --no-session-persistence \
    --debug-file "$LOGS/$tag.debug.log" \
    > "$LOGS/$tag.json" 2>>"$LOGS/run.log"

  if ! jq -e '.structured_output.verdict' "$LOGS/$tag.json" >/dev/null 2>&1; then
    say "  $tag: no structured output — failing closed"
    printf '{"verdict":"FAIL","findings":[{"file":"-","problem":"The %s invocation did not return a verdict (crash, timeout or budget cap).","fix":"Re-run; if it repeats, the diff is probably too large to review in one pass."}]}\n' "$tag" > "$out"
    return 0
  fi
  jq '.structured_output' "$LOGS/$tag.json" > "$out"
  say "  $tag: $(jq -r .verdict "$out") ($(jq -r '.findings|length' "$out") findings) cost=\$$(jq -r '.total_cost_usd // 0' "$LOGS/$tag.json")"
}

# findings_text <verdict-json...> : the findings as a flat list for the fixer
findings_text() {
  jq -r '.findings[] | "- \(.file): \(.problem)\n  FIX: \(.fix)"' "$@"
}

# --- the loop --------------------------------------------------------------------

done_count=0
while :; do
  [ "$MAX_ISSUES" -gt 0 ] && [ "$done_count" -ge "$MAX_ISSUES" ] && { say "hit MAX_ISSUES=$MAX_ISSUES"; break; }

  # The queue: open issues, lowest number first (the issues are numbered in dependency
  # order), minus any this run already gave up on.
  # (the skip list is read in BEGIN rather than as a first file argument: the NR==FNR
  #  idiom silently swallows the whole queue when the skip file is empty)
  N=$(gh issue list --state open --limit 300 --json number --jq '[.[].number] | sort | .[]' \
      | awk -v sf="$SKIPPED" 'BEGIN { while ((getline l < sf) > 0) skip[l] } !($0 in skip)' \
      | head -1)
  [ -n "$N" ] || { say "no open issues left — done"; break; }

  TITLE=$(gh issue view "$N" --json title --jq .title)
  BASE=$(git rev-parse HEAD)
  gh issue view "$N" --comments > "$LOGS/issue-$N.md"
  say "=== issue #$N: $TITLE (base $(git rev-parse --short "$BASE")) ==="

  { cat "$HARNESS/prompts/implement.md"
    echo "## Issue #$N: $TITLE"; echo
    cat "$LOGS/issue-$N.md"
  } | work "$N-implement"

  approved=0
  for round in $(seq 1 "$MAX_ROUNDS"); do

    # 1. Deterministic gate. Never spend model tokens reviewing code that does not build.
    if ! REPO="$REPO" "$HARNESS/gate.sh" > "$LOGS/$N-gate-$round.txt" 2>&1; then
      say "  round $round: gate failed"
      { cat "$HARNESS/prompts/fix.md"
        echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
        echo "## Failing checks"; echo '```'; cat "$LOGS/$N-gate-$round.txt"; echo '```'
      } | work "$N-fix-$round"
      continue
    fi
    say "  round $round: gate clean"

    # 2. The diff the critics judge. Staged so that newly created files are included.
    git add -A
    git diff --cached "$BASE" > "$LOGS/$N-diff-$round.patch"
    if [ ! -s "$LOGS/$N-diff-$round.patch" ]; then
      say "  round $round: empty diff — the implementer changed nothing"
      break
    fi
    if [ "$(wc -c < "$LOGS/$N-diff-$round.patch")" -gt "$MAX_DIFF_BYTES" ]; then
      say "  round $round: WARNING diff exceeds $MAX_DIFF_BYTES bytes — critics see a truncated diff"
    fi

    # 3. Both critics, concurrently, on the same diff.
    for role in review idiom; do
      { cat "$HARNESS/prompts/$role.md"
        echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
        echo "## What the implementer says it did"; echo; cat "$LOGS/$N-implement.txt"; echo
        echo "## The diff under review (since $BASE)"; echo '```diff'
        head -c "$MAX_DIFF_BYTES" "$LOGS/$N-diff-$round.patch"; echo '```'
      } | critic "$N-$role-$round" "$LOGS/$N-$role-$round.verdict.json" &
    done
    wait

    v_review=$(jq -r '.verdict' "$LOGS/$N-review-$round.verdict.json")
    v_idiom=$(jq -r '.verdict' "$LOGS/$N-idiom-$round.verdict.json")
    if [ "$v_review" = PASS ] && [ "$v_idiom" = PASS ]; then
      approved=1
      say "  round $round: both critics PASS"
      break
    fi

    # 4. Fix, then round again.
    say "  round $round: review=$v_review idiom=$v_idiom — sending findings back"
    { cat "$HARNESS/prompts/fix.md"
      echo "## Issue #$N: $TITLE"; echo; cat "$LOGS/issue-$N.md"; echo
      echo "## Blocking findings — correctness reviewer"; echo
      findings_text "$LOGS/$N-review-$round.verdict.json"; echo
      echo "## Blocking findings — idiom critic"; echo
      findings_text "$LOGS/$N-idiom-$round.verdict.json"
    } | work "$N-fix-$round"
  done

  # --- land it, or hand it to a human ---
  git add -A
  if [ "$approved" = 1 ]; then
    if git diff --cached --quiet "$BASE"; then
      say "#$N approved but the tree matches base — closing without a commit"
    else
      git commit -q -m "$TITLE" -m "Closes #$N" -m "Implemented by the ArchUnitDev loop." \
        || die "commit failed for #$N"
      git push -q origin HEAD || say "WARNING: push failed for #$N — commit is local only"
    fi
    gh issue close "$N" --comment "Implemented by the ArchUnitDev loop; both reviewers passed." >/dev/null \
      || say "WARNING: could not close #$N"
    say "#$N DONE"
    done_count=$((done_count + 1))
  else
    # Abandon: keep the work on a branch so nothing is lost, reset main, move on.
    say "#$N ABANDONED after $MAX_ROUNDS rounds — parking the work and leaving the issue open"
    if ! git diff --cached --quiet "$BASE"; then
      branch="abandoned/issue-$N"
      git commit -q -m "WIP #$N: $TITLE" -m "Abandoned by the ArchUnitDev loop after $MAX_ROUNDS rounds. Needs a human."
      git branch -f "$branch" HEAD
      git push -q origin "$branch" || say "WARNING: could not push $branch"
      git reset -q --hard "$BASE"
      say "#$N work parked on $branch; $REPO reset to $(git rev-parse --short "$BASE")"
    fi
    gh issue edit "$N" --add-label needs-human >/dev/null 2>&1 \
      || gh issue comment "$N" --body "The ArchUnitDev loop could not get this past review in $MAX_ROUNDS rounds. Needs a human." >/dev/null 2>&1 \
      || say "WARNING: could not annotate #$N"
    echo "$N" >> "$SKIPPED"
  fi
done

say "run finished: $done_count issue(s) landed, $(wc -l < "$SKIPPED" | tr -d ' ') abandoned"
say "total spend: \$$(jq -s '[.[].total_cost_usd // 0] | add' "$LOGS"/*.json 2>/dev/null)"

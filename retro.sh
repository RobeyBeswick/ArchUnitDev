#!/usr/bin/env bash
#
# A retrospective on the loop, run after a batch. Its subject is the machinery — the prompts, the
# gate, the round structure — not the code the loop wrote; the critics already judged that.
#
#   ./retro.sh              # every issue with artifacts in LOGS
#   ./retro.sh 11 12 13     # just these
#
# Two reasons this is a separate script rather than a step inside run.sh. It is not on the critical
# path, so a retrospective that crashes must not be able to affect a night's work; and the questions
# worth asking are cross-issue ("which critic never fails?"), which cannot be answered until a batch
# is done. run.sh runs it at the end when RETRO=1, and that is the only coupling.
#
# It is read-only by tool restriction, like the critics: it proposes changes to the harness in a
# report, and a human decides. A pass that edits the prompts it is judging is one nobody can audit,
# and it would also be editing files a running loop has open.
#
set -uo pipefail

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS="${LOGS:-$HARNESS/logs}"
[ -d "$LOGS" ] || { echo "FATAL: LOGS=$LOGS is not a directory — there is nothing to review" >&2; exit 1; }
LOGS="$(cd "$LOGS" && pwd)"
REPO="${REPO:-/work/repo}"

MAX_ROUNDS="${MAX_ROUNDS:-3}"
CRITICS=(review idiom tests)
TIMEOUT="${TIMEOUT:-30m}"
MODEL="${MODEL:-opencode-go/deepseek-v4-flash}"
VARIANT="${VARIANT:-high}"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
OUT="${OUT:-$LOGS/retro-$STAMP.md}"

say() { printf '%s  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOGS/run.log"; }

command -v opencode >/dev/null || { say "retro: opencode not on PATH"; exit 1; }
command -v jq     >/dev/null || { say "retro: jq not on PATH"; exit 1; }
export OPENCODE_CONFIG_DIR="$HARNESS/opencode"

# The subject. Given explicitly, or every issue this log directory holds an implementer run for —
# which on a long-lived log directory is *every batch ever run into it*, not just the last one. That
# is usually what you want from a retrospective and occasionally not, hence the arguments.
if [ "$#" -gt 0 ]; then
  ISSUES=("$@")
else
  ISSUES=()
  for f in "$LOGS"/*-implement.json; do
    [ -e "$f" ] || continue
    n="${f##*/}"; n="${n%%-implement.json}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    ISSUES+=("$n")
  done
  # `sort -n` on the list rather than relying on glob order, which is lexical: 10 before 2.
  if [ "${#ISSUES[@]}" -gt 0 ]; then
    # shellcheck disable=SC2207
    ISSUES=($(printf '%s\n' "${ISSUES[@]}" | sort -n))
  fi
fi
[ "${#ISSUES[@]}" -gt 0 ] || { say "retro: no issue artifacts in $LOGS — nothing to review"; exit 0; }

# --- the evidence pack ------------------------------------------------------------------------
#
# Computed, not summarised: every number below comes from an artifact, so the model is not asked to
# count things it would sometimes miscount, and the report can be checked against the same files.
# What it deliberately does not do is quote the diffs or the findings — those are on disk and the
# prompt tells the retrospective to go and read them. Pasting them in would cost more than the whole
# invocation and still be less than it can see for itself.
pack="$LOGS/.retro-pack.$$"
trap 'rm -f "$pack"' EXIT

{
  printf '# Evidence pack\n\n'
  printf 'Log directory: `%s` — every path below is relative to it, and you can Read them.\n' "$LOGS"
  printf 'Target repo: `%s` (its current state is the batch outcome).\n' "$REPO"
  printf 'Issues in this batch: %s. MAX_ROUNDS was %s.\n\n' "${ISSUES[*]}" "$MAX_ROUNDS"

  for N in "${ISSUES[@]}"; do
    title=$(head -1 "$LOGS/issue-$N.md" 2>/dev/null | sed 's/^# //')
    # Outcome from the two state files rather than from the narration: `landed` means it was
    # committed with the issue deliberately left open, which is what NO_PUSH does.
    outcome="landed and pushed"
    grep -qx "$N" "$LOGS/landed"  2>/dev/null && outcome="landed, issue left open (NO_PUSH)"
    grep -qx "$N" "$LOGS/skipped" 2>/dev/null && outcome="ABANDONED — no unanimous pass"
    # An issue with two attempts is worth flagging in the heading rather than leaving to be inferred
    # from the round tables below: whether the second attempt was worth its money is a question about
    # the loop, which is what this whole exercise is for.
    if [ -f "$LOGS/$N-retry-implement.json" ]; then
      case "$outcome" in
        ABANDONED*) outcome="$outcome, twice — abandoned, re-attempted on a later base, abandoned again" ;;
        *)          outcome="$outcome, but only on the re-attempt: the first attempt of it was abandoned" ;;
      esac
    fi

    # The glob spans both attempts, which is the honest total: what the issue cost this batch.
    cost=$(jq -s '[.[].total_cost_usd // 0] | add' "$LOGS/$N-"*.json 2>/dev/null)
    printf '## Issue #%s — %s\n' "$N" "${title:-(no issue-$N.md)}"
    printf 'Outcome: %s. Total spend: $%s. Description: %s bytes.\n' \
      "$outcome" "${cost:-0}" "$(wc -c < "$LOGS/issue-$N.md" 2>/dev/null | tr -d ' ')"

    for TAG in "$N" "$N-retry"; do
    [ -f "$LOGS/$TAG-implement.json" ] || continue
    [ "$TAG" = "$N" ] || printf '\nRe-attempted from scratch on a later base, the first attempt having been abandoned:\n'
    # MAX_ROUNDS + 1, because that is how many rounds run.sh runs: the extra one is the verdict taken
    # after the last fix, and it is the round that decides every abandoned issue. Walking to MAX_ROUNDS
    # instead drops it — so the retrospective would see an issue's last fix and none of the judgement
    # on it, which is the opposite of what the round is for.
    for round in $(seq 1 $((MAX_ROUNDS + 1))); do
      [ -f "$LOGS/$TAG-gate-$round.txt" ] || continue
      # The gate is clean exactly when the diff for that round exists: run.sh writes the diff only
      # after the gate passes, and jumps straight to the fixer when it does not.
      if [ -f "$LOGS/$TAG-diff-$round.patch" ]; then
        gate="clean"
      else
        gate="FAILED"
        violations=$(grep -c 'VIOLATION' "$LOGS/$TAG-gate-$round.txt" 2>/dev/null | tr -d ' ')
        [ "${violations:-0}" -gt 0 ] && gate="FAILED ($violations VIOLATION line(s); the rest is build/test output — read the file)"
      fi
      printf '* round %s: gate %s' "$round" "$gate"
      if [ -f "$LOGS/$TAG-diff-$round.patch" ]; then
        printf ', diff %s bytes over %s file(s)' \
          "$(wc -c < "$LOGS/$TAG-diff-$round.patch" | tr -d ' ')" \
          "$(grep -c '^+++ ' "$LOGS/$TAG-diff-$round.patch" 2>/dev/null | tr -d ' ')"
      fi
      for role in "${CRITICS[@]}"; do
        v="$LOGS/$TAG-$role-$round.verdict.json"
        [ -f "$v" ] || continue
        printf ' | %s %s (%s finding(s))' \
          "$role" "$(jq -r '.verdict // "?"' "$v")" "$(jq -r '.findings | length' "$v" 2>/dev/null)"
      done
      [ -f "$LOGS/$TAG-fix-$round.json" ] && printf ' | fixer ran'
      printf '\n'
    done
    done
    printf '\n'
  done

  # The narration, last. It is the only place the *order* of events survives, including the warnings
  # run.sh emits about things no artifact records — a thin issue description, a missing tool.
  printf '## The narration (run.log, last 200 lines)\n\n```\n'
  tail -200 "$LOGS/run.log" 2>/dev/null
  printf '```\n'
} > "$pack"

# The pack is the part worth checking by hand — every number in the report is downstream of it — and
# printing it costs nothing, which a model invocation does not.
if [ -n "${PACK_ONLY:-}" ]; then
  cat "$pack"
  exit 0
fi

say "retro: reviewing issue(s) ${ISSUES[*]} — pack is $(wc -c < "$pack" | tr -d ' ') bytes"

# The retrospective reads across LOGS and REPO — two directories — which the read-only agent can do
# because external_directory is left allowed on it. GH_TOKEN is stripped for the same reason it is
# stripped from every other model invocation: nothing here has any business closing an issue or pushing.
timeout_cmd=()
command -v timeout >/dev/null && timeout_cmd=(timeout "$TIMEOUT")
variant=()
[ -n "${VARIANT:-}" ] && variant=(--variant "$VARIANT")

{ cat "$HARNESS/prompts/retro.md"; printf '\n---\n\n'; cat "$pack"; } \
  | env -u GH_TOKEN -u GITHUB_TOKEN \
    ${timeout_cmd[@]+"${timeout_cmd[@]}"} opencode run \
      --format json \
      --model "$MODEL" \
      ${variant[@]+"${variant[@]}"} \
      --agent readonly \
      --dir "$REPO" \
      --title "retro-$STAMP" \
      > "$LOGS/retro-$STAMP.jsonl" 2>>"$LOGS/run.log"
rc=$?

# The same synthesis as run.sh: the report is the last text part, the cost the sum of the steps.
jq -s '{
    type: "result", subtype: "success", is_error: false,
    result: ([.[] | select(.type=="text") | .part.text // empty] | last // ""),
    total_cost_usd: ([.[] | select(.type=="step_finish") | .part.cost // 0] | add // 0)
  }' "$LOGS/retro-$STAMP.jsonl" > "$LOGS/retro-$STAMP.json"

report=$(jq -r '.result // empty' "$LOGS/retro-$STAMP.json" 2>/dev/null)
if [ -z "$report" ]; then
  say "retro: no report came back (rc=$rc) — see retro-$STAMP.json and retro-$STAMP.jsonl"
  exit 1
fi
printf '%s\n' "$report" > "$OUT"
say "retro: $OUT (cost \$$(jq -r '.total_cost_usd // 0' "$LOGS/retro-$STAMP.json"))"

# To stdout as well as to the file. Under `nohup ... > loop.out` that puts it in the log directory
# the sync carries to S3, so the report leaves the instance with everything else.
printf '\n%s\n' "$report"

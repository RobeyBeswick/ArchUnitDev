#!/bin/bash
#
# ArchUnitSharpTest on Opus 5.5: #38 and #39 again with the limits turned up as far as they go, then
# the rest of the backlog (#40-#46) at the benchmark's own settings.
#
# The benchmark run (RUN_ID sharp-opus55-20260923T103101Z, MAX_ROUNDS=3 TIMEOUT=60m VARIANT=high)
# landed #1-#37 and then abandoned #38 (Pattern exclusions) and #39 (Logging) back to back, which
# tripped MAX_CONSECUTIVE_ABANDONS=2 and stopped it at 01:33Z with six issues never attempted. Neither
# abandonment was the environment: the gate was clean in every round of both, and every round's
# findings were new and real (a doc example the folder rules contradict, a `Release(fullPath)` whose
# deletion no test catches). Both ran out of runway while still converging. And because the breaker
# calls die(), the retry phase that would have given each a second attempt never ran.
#
# So, in two phases, one container:
#
#   A. #38, then #39, each alone in the queue, for up to ATTEMPTS=5 fresh attempts (was 1, plus a
#      retry that never ran):
#        MAX_ROUNDS=15    15 fixes and a 16th round that judges without fixing (was 3)
#        TIMEOUT=240m     per invocation (was 60m)
#        VARIANT=high     unchanged. `max` was tried first and its first implement died in 3 seconds
#                         with "Unexpected server error" at $0; the decision was then to buy the extra
#                         runway with attempts, rounds and time, and keep reasoning effort where every
#                         other issue in the benchmark had it, so the model is the same one throughout.
#        CARRY_FINDINGS=1 each attempt starts from the previous attempt's outstanding findings
#      An attempt is its own run.sh invocation with its own log directory under logs/bruteforce/, because
#      run.sh names files by issue, role and round: a second run over the same directory overwrites
#      the first attempt's .json/.jsonl and its token data is gone for good. log-sync already ships
#      logs/ recursively, so the attempts land in the same S3 prefix as the benchmark.
#
#   B. #40-#46 (not #44, held back from the start) at the benchmark's settings, in the benchmark's own
#      log directory, so the report reads one ledger. Two deviations, both recorded in the README:
#      MAX_CONSECUTIVE_ABANDONS=0, because the breaker has already fired once on hard issues rather than
#      a broken environment and a second false stop costs another night; and #38/#39 held back if phase
#      A did not land them, since they have had their attempts.
#
# This is what "brute force" means here: more attempts, more rounds and more time. Not a different
# prompt, a different model, a different reasoning effort, or any relaxation of the gate or the critics — an issue still
# lands only on a unanimous PASS over a clean gate.
#
# Run as root on the loop host:  sudo bash deploy/runs/sharp-opus55-bruteforce.sh
# The script re-runs itself inside the loop image (`inside` below) so that git pushes the parked
# branches with the same `gh` credential helper run.sh uses, and the token never touches the disk.
#
set -uo pipefail

ISSUES="${ISSUES:-38 39}"
ATTEMPTS="${ATTEMPTS:-5}"
BF_KNOBS=(MAX_ROUNDS=15 TIMEOUT=240m VARIANT=high CARRY_FINDINGS=1 MAX_ISSUES=1
          MAX_CONSECUTIVE_ABANDONS=0 RETRY_ABANDONED= MAX_SPEND=0)
B_KNOBS=(MAX_ROUNDS=3 TIMEOUT=60m VARIANT=high MAX_ISSUES=0
         MAX_CONSECUTIVE_ABANDONS=0 RETRY_ABANDONED=1 MAX_SPEND=0)

say() { printf '%s  bruteforce: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# ---------------------------------------------------------------------------------------------------
# Inside the container: /work/repo is the target, /work/logs the benchmark's log directory.
if [ "${1:-}" = inside ]; then
  cd /work/repo || exit 1
  CRED=(-c 'credential.https://github.com.helper=!gh auth git-credential')
  BF=/work/logs/bruteforce
  mkdir -p "$BF"
  # The loop never fetches, so HEAD is whatever the last batch left. Checked in here rather than on
  # the host because this is where the credential helper is.
  remote=$(git "${CRED[@]}" ls-remote origin refs/heads/main | cut -f1)
  [ -n "$remote" ] && [ "$remote" = "$(git rev-parse HEAD)" ] \
    || { say "REFUSING: HEAD $(git rev-parse --short HEAD) is not origin/main ${remote:0:7}"; exit 1; }

  for n in $ISSUES; do
    prev=/work/logs          # the benchmark's abandoned attempt holds the first findings to carry
    k=1 crashes=0
    while [ "$k" -le "$ATTEMPTS" ]; do
      state=$(gh issue view "$n" --json state --jq .state)
      [ "$state" = CLOSED ] && { say "#$n is already closed — nothing to do"; break; }
      [ "$state" = OPEN ] || { say "STOPPING: cannot read #$n's state from GitHub"; exit 1; }
      d="$BF/$n-attempt-$k"
      [ -e "$d" ] && { say "REFUSING: $d already exists — move it aside first"; exit 1; }
      mkdir -p "$d"
      cp "$prev/$n"-*.verdict.json "$d/" 2>/dev/null
      carried=$(find "$d" -name "$n-*.verdict.json" | wc -l | tr -d ' ')
      [ "$carried" -gt 0 ] || { say "REFUSING: no verdicts for #$n in $prev — CARRY_FINDINGS would carry nothing, silently"; exit 1; }
      # The queue is "the lowest open issue not in skipped", so holding back every other open issue
      # is how one run.sh invocation is pointed at exactly one issue.
      gh issue list --state open --limit 300 --json number --jq '.[].number' | awk -v n="$n" '$0 != n' > "$d/skipped"
      : > "$d/landed"
      # run.sh parks an abandoned attempt on abandoned/issue-N with `git branch -f`. Locally that name
      # still holds the benchmark's attempt, which origin also has — so the local copy can go, and each
      # attempt here is renamed after it parks, before the next one reuses the name.
      if git rev-parse -q --verify "refs/heads/abandoned/issue-$n" >/dev/null; then
        if [ "$(git rev-parse "abandoned/issue-$n")" = "$(git rev-parse -q --verify "refs/remotes/origin/abandoned/issue-$n")" ]; then
          git branch -D "abandoned/issue-$n" >/dev/null
        else
          say "REFUSING: local abandoned/issue-$n is not on origin — it would be overwritten"; exit 1
        fi
      fi
      say "#$n attempt $k/$ATTEMPTS: ${BF_KNOBS[*]}, carrying $carried verdict file(s) from $(basename "$prev")"
      started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
      env "${BF_KNOBS[@]}" LOGS="$d" /harness/run.sh
      rc=$?
      # CLOSED, not "not OPEN": a gh call that fails prints nothing, and that must not read as a landing.
      if [ "$(gh issue view "$n" --json state --jq .state)" = CLOSED ]; then
        say "#$n LANDED on brute-force attempt $k (run.sh rc=$rc)"
        break
      fi
      log=$(cat "$d/run.log" 2>/dev/null)
      case "$log" in
        *"#$n ABANDONED"*) ;;
        *) say "STOPPING: #$n attempt $k ended without landing or abandoning (rc=$rc) — read $d/run.log"; exit 1 ;;
      esac
      # The first brute-force launch lost attempt 1 this way: opencode's session was created, then the
      # implement exited rc=1 three seconds later with "Unexpected server error", $0 and no turns, and
      # run.sh abandoned an empty diff and posted "could not get this past review in 15 rounds" on an
      # issue no model had looked at. The next invocation in the same container ran normally. That is
      # not an attempt, so it is not counted: its directory is set aside, the comment it posted is
      # deleted, and the attempt runs again, at most three times before the script gives up.
      case "$log" in
        *"$n-implement: rc="*" cost=\$0 turns=0 "*"#$n ABANDONED — the implementer changed nothing on round 1"*)
          crashes=$((crashes + 1))
          mv "$d" "$BF/crashed-$n-attempt-$k-$crashes"
          gh api "repos/{owner}/{repo}/issues/$n/comments" --paginate \
             --jq ".[] | select(.created_at >= \"$started\") | select(.body | test(\"Needs a human\")) | .id" \
            | while read -r c; do gh api -X DELETE "repos/{owner}/{repo}/issues/comments/$c" >/dev/null && say "deleted comment $c"; done
          [ "$crashes" -lt 3 ] || { say "STOPPING: #$n's implement crashed at \$0 $crashes times in a row"; exit 1; }
          say "#$n attempt $k: the implement crashed before its first turn — not counted, running it again"
          continue ;;
      esac
      crashes=0
      if git rev-parse -q --verify "refs/heads/abandoned/issue-$n" >/dev/null; then
        b="abandoned/issue-$n-bruteforce-$k"
        git branch -m "abandoned/issue-$n" "$b"
        git "${CRED[@]}" push -q origin "$b" && say "#$n attempt $k parked on $b" || say "WARNING: could not push $b"
      fi
      say "#$n abandoned on brute-force attempt $k"
      prev="$d"
      k=$((k + 1))
    done
  done

  # Phase B. The benchmark's own directory and settings; skipped rebuilt to exactly what is held back.
  { echo 44; for n in $ISSUES; do [ "$(gh issue view "$n" --json state --jq .state)" = CLOSED ] || echo "$n"; done; } > /work/logs/skipped
  say "phase B: #40-#46 at ${B_KNOBS[*]}; held back: $(tr '\n' ' ' < /work/logs/skipped)"
  env "${B_KNOBS[@]}" LOGS=/work/logs /harness/run.sh
  say "phase B exited (rc=$?)"
  exit 0
fi

# ---------------------------------------------------------------------------------------------------
# On the host, as root.
[ -r /etc/profile.d/archunitdev.sh ] && . /etc/profile.d/archunitdev.sh
: "${IMAGE:?}" "${REPO_DIR:?}" "${LOGS_DIR:?}" "${GH_TOKEN_SECRET:?}" "${AWS_REGION:?}"
H=/home/ec2-user

# The four ways a relaunch on a used host fails open (deploy/README, AGENTS.md): a loop already
# running, HEAD not origin's tip (checked inside, where gh is), no credential, a stale image. Plus the
# missing-verdicts check, which is the quiet way CARRY_FINDINGS fails open.
running=$(docker ps --format '{{.Command}}')
case "$running" in *run.sh*|*bruteforce*) say "REFUSING: a loop is already running"; exit 1 ;; esac
g() { sudo -u ec2-user git -C "$REPO_DIR" "$@"; }
[ -z "$(g status --porcelain)" ] || { say "REFUSING: the target repo has uncommitted changes"; exit 1; }
[ "$(g rev-parse --abbrev-ref HEAD)" = main ] || { say "REFUSING: the target repo is not on main"; exit 1; }

export GH_TOKEN="$(aws secretsmanager get-secret-value --region "$AWS_REGION" --cli-read-timeout 60 \
  --secret-id "$GH_TOKEN_SECRET" --query SecretString --output text)"
[ -n "$GH_TOKEN" ] || { say "REFUSING: the GitHub token came back empty"; exit 1; }
for n in $ISSUES; do
  ls "$LOGS_DIR/$n"-*.verdict.json >/dev/null 2>&1 || { say "REFUSING: no verdicts for #$n in $LOGS_DIR"; exit 1; }
done
case "$(docker run --rm --entrypoint cat "$IMAGE" /harness/run.sh)" in
  *CARRY_FINDINGS*) ;; *) say "REFUSING: the image's run.sh has no CARRY_FINDINGS — stale image"; exit 1 ;;
esac

self="$(readlink -f "$0")"
say "launching: ISSUES='$ISSUES' ATTEMPTS=$ATTEMPTS, then phase B"
docker rm -f archunitdev-loop >/dev/null 2>&1
docker run -d --name archunitdev-loop \
  -e GH_TOKEN -e TARGET_LANG -e AWS_REGION -e AWS_PROFILE=loop -e AWS_CONFIG_FILE=/home/dev/.aws-loop/config \
  -e MODEL=amazon-bedrock/us.anthropic.claude-opus-5-5 -e FLASH_MODEL=amazon-bedrock/us.anthropic.claude-opus-5-5 \
  -e ISSUES="$ISSUES" -e ATTEMPTS="$ATTEMPTS" \
  -v "$H/.aws-loop:/home/dev/.aws-loop:ro" -v "$REPO_DIR:/work/repo" -v "$LOGS_DIR:/work/logs" \
  -v "$self:/work/bruteforce.sh:ro" \
  --entrypoint bash "$IMAGE" /work/bruteforce.sh inside
unset GH_TOKEN
say "started; follow with: docker logs -f archunitdev-loop"

#!/bin/bash
# Stop the batch as soon as #34 resolves, so the rest of the queue can be re-run with limits that fit
# it. The batch is configured MAX_ROUNDS=4 / TIMEOUT=45m, which is the configuration that stranded #30
# and #31: both implementers were cut off at 45m, spent a round on the partial diff, and ran out of
# fixes while the test critic was still finding real holes. #35-#44 would run under the same terms.
# It would also stop itself around #41 on MAX_SPEND=600, by the `break` path that skips the retry
# phase — so anything it abandoned from here would get no second attempt either.
#
# Waiting for #34 rather than stopping now: it is part-way through, and an interrupted implement is
# the exact input that produced the two failures. Let it land or abandon on its own terms.
#
# Nothing here touches the repo. `docker stop` ends the loop; batch27.sh then runs its own bundle step,
# which is how the commits get off this volume.
log=/home/ec2-user/logs/run.log
chain=/home/ec2-user/logs/chain.log
say() { printf '%s  stop-at-34: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$chain"; }

# 4 hours at 3s. #34 could legitimately take a while: four fix rounds with a 45m step timeout is a
# long way from the 20 minutes #33 needed.
for _ in $(seq 1 4800); do
  if grep -qE '#34 (DONE|ABANDONED)' "$log"; then
    say "#34 resolved — stopping the batch so #35-#44 can be re-run with MAX_ROUNDS=10 and TIMEOUT=120m"
    docker ps -q --filter 'ancestor=archunitdev' | xargs -r docker stop -t 60
    docker ps -a --format '{{.ID}} {{.Command}}' | awk '/run\.sh/ {print $1}' | xargs -r docker stop -t 60
    say "stopped"
    exit 0
  fi
  sleep 3
done
say "gave up waiting for #34 after 4 hours — the batch is still running and has NOT been stopped"

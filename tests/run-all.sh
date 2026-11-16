#!/usr/bin/env bash
# Run the full T01–T09 suite and print a summary of this run.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$TESTS_DIR/lib/common.sh"

TESTS=(
  t01-baseline.sh
  t02-app-failover.sh
  t03-app-failover-reverse.sh
  t04-lb-failover.sh
  t05-lb-restore.sh
  t06-db-primary-failure.sh
  t07-db-promote-reconnect.sh
  t08-attachment.sh
  t09-rejoin.sh
)

before=0
[[ -f "$RESULTS" ]] && before=$(wc -l < "$RESULTS")

say ""
say "###############################################################"
say "#  HA ERP failure-injection suite"
say "#  started $(date -u +%FT%TZ)"
say "#  evidence: $EVIDENCE_DIR"
say "###############################################################"

declare -A outcomes
overall=0
for t in "${TESTS[@]}"; do
  if [[ ! -x "$TESTS_DIR/$t" ]]; then
    note "skipping $t (not executable)"; outcomes[$t]=skip; continue
  fi
  if "$TESTS_DIR/$t"; then
    outcomes[$t]=pass
  else
    outcomes[$t]=fail
    overall=1
    bad "$t failed — continuing (the lab state is recorded in the log)"
  fi
done

say ""
say "=========================== SUMMARY ==========================="
printf '  %-28s %-6s\n' TEST RESULT
for t in "${TESTS[@]}"; do
  printf '  %-28s %-6s\n' "${t%.sh}" "${outcomes[$t]:-skip}"
done | tee -a "$EVIDENCE_DIR/summary.log"

if [[ -f "$RESULTS" ]]; then
  after=$(wc -l < "$RESULTS")
  if (( after > before )); then
    say ""
    say "Metrics for this run:"
    tail -n +$((before + 1)) "$RESULTS" \
      | jq -r '[.test, .status, (.rto_s // "-" | tostring), (.detection_s // "-" | tostring),
                (.availability_pct // "-" | tostring), (.notes // "")] | @tsv' \
      | (printf 'TEST\tSTATUS\tRTO_s\tDETECT_s\tAVAIL_%%\tNOTES\n'; cat) \
      | column -t -s $'\t'
  fi
fi

say ""
say "finished $(date -u +%FT%TZ) — exit ${overall}"
exit $overall

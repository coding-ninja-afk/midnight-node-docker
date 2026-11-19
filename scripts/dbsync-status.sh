#!/usr/bin/env bash
# Report cardano-db-sync progress against the local cardano-node tip and evaluate the
# catch-up criteria from RUNBOOK.md section 7. All times are UTC.
#
# Usage:
#   scripts/dbsync-status.sh                 one sample, checks 1-3 and 5
#   scripts/dbsync-status.sh --advance 300   two samples 300 s apart, adds check 4
#
# Exit codes: 0 = caught up (all evaluated checks pass), 1 = not caught up yet,
#             2 = could not query (container down, bad arguments).
set -euo pipefail
cd "$(dirname "$0")/.."

# Thresholds: rationale in RUNBOOK.md section 7.
MAX_BLOCK_GAP=5        # node block - db-sync block
MAX_LAG_SECONDS=300    # age of db-sync's newest block
LOG_WINDOW=15m         # window for the "no errors" check
PREPROD_MAGIC=1        # PreProd network magic

advance=0
if [[ "${1:-}" == "--advance" ]]; then
  advance="${2:-}"
  [[ "$advance" =~ ^[0-9]+$ && "$advance" -gt 0 ]] || { echo "usage: $0 [--advance SECONDS]" >&2; exit 2; }
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--advance SECONDS]" >&2; exit 2
fi

dc() { docker compose -f compose-partner-chains.yml "$@"; }

for svc in cardano-node postgres cardano-db-sync; do
  if [[ -z "$(dc ps --status running -q "$svc" 2>/dev/null)" ]]; then
    echo "error: service '$svc' is not running (docker compose -f compose-partner-chains.yml ps)" >&2
    exit 2
  fi
done

# psql over the in-container socket; credentials never leave the container.
# shellcheck disable=SC2016  # $(cat ...) must expand inside the container, not here
psql_q() {
  dc exec -T postgres sh -c \
    'psql -X -At -F "|" -v ON_ERROR_STOP=1 -U "$(cat /run/secrets/postgres_user)" -d "$(cat /run/secrets/postgres_db)" -c "$1"' _ "$1"
}

# Sets globals: TS NODE_BLOCK NODE_PROGRESS DB_BLOCK DB_SLOT DB_EPOCH DB_TIME DB_LAG
sample() {
  TS="$(date -u +%FT%TZ)"
  local tip
  tip="$(dc exec -T cardano-node cardano-cli query tip --testnet-magic "$PREPROD_MAGIC" --socket-path /ipc/node.socket)" \
    || { echo "error: cardano-node did not answer 'query tip'" >&2; exit 2; }
  NODE_BLOCK="$(jq -r '.block' <<<"$tip")"
  NODE_PROGRESS="$(jq -r '.syncProgress' <<<"$tip")"

  local row
  row="$(psql_q "SELECT block_no, slot_no, epoch_no, to_char(time, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
                        floor(EXTRACT(epoch FROM (now() AT TIME ZONE 'UTC') - time))::bigint
                 FROM block WHERE block_no IS NOT NULL ORDER BY id DESC LIMIT 1;")" \
    || { echo "error: query against db-sync database failed" >&2; exit 2; }
  [[ -n "$row" ]] || { echo "error: db-sync has not inserted any block yet" >&2; exit 2; }
  IFS='|' read -r DB_BLOCK DB_SLOT DB_EPOCH DB_TIME DB_LAG <<<"$row"
}

print_sample() {
  printf '%s  node: block=%s syncProgress=%s  db-sync: block=%s slot=%s epoch=%s block_time=%s lag=%ss gap=%s\n' \
    "$TS" "$NODE_BLOCK" "$NODE_PROGRESS" "$DB_BLOCK" "$DB_SLOT" "$DB_EPOCH" "$DB_TIME" "$DB_LAG" \
    "$((NODE_BLOCK - DB_BLOCK))"
}

failed=0
check() {  # $1=label $2=detail $3...=test command; evaluated inside "if" so set -e can't abort
  local label="$1" detail="$2"; shift 2
  if "$@"; then echo "PASS  $label  ($detail)"; else echo "FAIL  $label  ($detail)"; failed=1; fi
}

sample; print_sample
first_block="$DB_BLOCK"; first_ts="$TS"

if (( advance > 0 )); then
  sleep "$advance"
  sample; print_sample
fi

echo
check "1 node syncProgress = 100.00" "$NODE_PROGRESS" [ "$NODE_PROGRESS" = "100.00" ]
check "2 block gap <= $MAX_BLOCK_GAP" "$((NODE_BLOCK - DB_BLOCK))" [ "$((NODE_BLOCK - DB_BLOCK))" -le "$MAX_BLOCK_GAP" ]
check "3 newest block age < ${MAX_LAG_SECONDS}s" "${DB_LAG}s" [ "$DB_LAG" -lt "$MAX_LAG_SECONDS" ]
if (( advance > 0 )); then
  check "4 block_no advanced over ${advance}s" "$first_block@$first_ts -> $DB_BLOCK@$TS" [ "$DB_BLOCK" -gt "$first_block" ]
else
  echo "SKIP  4 still advancing  (run with --advance 300)"
fi
errors="$(dc logs --no-color --since "$LOG_WINDOW" cardano-db-sync 2>&1 | grep -ciE ':Error:|\bException\b' || true)"
check "5 no db-sync errors in last $LOG_WINDOW" "$errors error lines" [ "$errors" -eq 0 ]

echo
if (( failed )); then echo "RESULT: not caught up"; exit 1; fi
if (( advance == 0 )); then echo "RESULT: checks 1-3,5 pass; confirm check 4 with --advance 300"; exit 1; fi
echo "RESULT: caught up, Midnight may start"

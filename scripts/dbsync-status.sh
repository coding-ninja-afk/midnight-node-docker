#!/usr/bin/env bash
# Report cardano-db-sync progress against the local cardano-node tip and classify it as
# READY / CATCHING UP / FAULT using the criteria in RUNBOOK.md section 7. All times UTC.
#
# Usage:
#   scripts/dbsync-status.sh                 one sample (can at most say UNCONFIRMED)
#   scripts/dbsync-status.sh --advance 300   two samples 300 s apart (can say READY)
#
# Exit codes (shared with scripts/midnight-height-check.sh):
#   0 READY        caught up and still advancing; Midnight may start
#   1 FAULT        something is wrong (stall, db-sync ahead of node, errors in logs)
#   2 ERROR        could not query (container down, bad arguments)
#   3 CATCHING UP  healthy, not at the tip yet
#   4 UNCONFIRMED  at the tip on one sample; rerun with --advance to confirm
#
# Env (tuning/tests): DBSYNC_RETRIES (default 3), DBSYNC_RETRY_DELAY seconds (default 5)
set -euo pipefail
cd "$(dirname "$0")/.."

# Thresholds: rationale in RUNBOOK.md section 7.
MAX_BLOCK_GAP=5        # node block - db-sync block
MAX_LAG_SECONDS=300    # age of db-sync's newest block
LOG_WINDOW=15m         # window for the "no errors" check
PREPROD_MAGIC=1        # PreProd network magic
RETRIES="${DBSYNC_RETRIES:-3}"
RETRY_DELAY="${DBSYNC_RETRY_DELAY:-5}"

usage() { echo "usage: $0 [--advance SECONDS]" >&2; exit 2; }
advance=0
if [[ "${1:-}" == "--advance" ]]; then
  advance="${2:-}"
  [[ "$advance" =~ ^[0-9]+$ && "$advance" -gt 0 ]] || usage
elif [[ $# -gt 0 ]]; then
  usage
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

# One raw reading. Sets: TS DB_BLOCK DB_SLOT DB_EPOCH DB_TIME DB_LAG NODE_BLOCK NODE_PROGRESS GAP
# db-sync is read FIRST, the node SECOND. The node's block only grows (barring a rollback),
# so with this order a healthy reading always has GAP >= 0. A negative GAP is therefore not a
# timing artifact; it means db-sync holds blocks this node doesn't (node restarted on an
# older DB, deep rollback, or db-sync following a different node).
read_once() {
  TS="$(date -u +%FT%TZ)"
  local row tip
  row="$(psql_q "SELECT block_no, slot_no, epoch_no, to_char(time, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
                        floor(EXTRACT(epoch FROM (now() AT TIME ZONE 'UTC') - time))::bigint
                 FROM block WHERE block_no IS NOT NULL ORDER BY id DESC LIMIT 1;")" \
    || { echo "error: query against db-sync database failed" >&2; exit 2; }
  [[ -n "$row" ]] || { echo "error: db-sync has not inserted any block yet" >&2; exit 2; }
  IFS='|' read -r DB_BLOCK DB_SLOT DB_EPOCH DB_TIME DB_LAG <<<"$row"

  tip="$(dc exec -T cardano-node cardano-cli query tip --testnet-magic "$PREPROD_MAGIC" --socket-path /ipc/node.socket)" \
    || { echo "error: cardano-node did not answer 'query tip'" >&2; exit 2; }
  NODE_BLOCK="$(jq -r '.block' <<<"$tip")"
  NODE_PROGRESS="$(jq -r '.syncProgress' <<<"$tip")"
  [[ "$NODE_BLOCK" =~ ^[0-9]+$ && "$DB_BLOCK" =~ ^[0-9]+$ ]] \
    || { echo "error: unexpected reading (node block '$NODE_BLOCK', db-sync block '$DB_BLOCK')" >&2; exit 2; }
  GAP=$(( NODE_BLOCK - DB_BLOCK ))
}

print_reading() {
  printf '%s  db-sync: block=%s slot=%s epoch=%s block_time=%s lag=%ss  node: block=%s syncProgress=%s  gap=%s%s\n' \
    "$TS" "$DB_BLOCK" "$DB_SLOT" "$DB_EPOCH" "$DB_TIME" "$DB_LAG" "$NODE_BLOCK" "$NODE_PROGRESS" "$GAP" "${1:-}"
}

# A sample = a reading, retried while db-sync appears ahead of the node.
# Sets AHEAD_PERSISTED=1 if every attempt showed a negative gap.
AHEAD_PERSISTED=0
sample() {
  local attempt
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    read_once
    if (( GAP >= 0 )); then print_reading; return; fi
    if (( attempt < RETRIES )); then
      print_reading "  <- db-sync ahead of node, retry $attempt/$((RETRIES - 1)) in ${RETRY_DELAY}s"
      sleep "$RETRY_DELAY"
    else
      print_reading "  <- db-sync still ahead after $RETRIES readings"
      AHEAD_PERSISTED=1
    fi
  done
}

faults=() pending=()
check() {  # $1=kind (fault|pending) $2=label $3=detail $4...=test; runs inside "if" so set -e can't abort
  local kind="$1" label="$2" detail="$3"; shift 3
  if "$@"; then echo "PASS  $label  ($detail)"; return; fi
  if [[ "$kind" == fault ]]; then echo "FAULT $label  ($detail)"; faults+=("$label")
  else echo "WAIT  $label  ($detail)"; pending+=("$label"); fi
}

sample
first_block="$DB_BLOCK"; first_ts="$TS"; first_epoch_s="$(date -u +%s)"
if (( advance > 0 )); then
  sleep "$advance"
  sample
fi

echo
# Integrity first: these are FAULTs (something is wrong), not "not there yet".
check fault "0 db-sync not ahead of node" "gap=$GAP" [ "$AHEAD_PERSISTED" -eq 0 ]
errors="$(dc logs --no-color --since "$LOG_WINDOW" cardano-db-sync 2>&1 | grep -ciE ':Error:|\bException\b' || true)"
check fault "5 no db-sync errors in last $LOG_WINDOW" "$errors error lines" [ "$errors" -eq 0 ]
if (( advance > 0 )); then
  check fault "4 block_no advanced over ${advance}s" "$first_block@$first_ts -> $DB_BLOCK@$TS" [ "$DB_BLOCK" -gt "$first_block" ]
fi
# Readiness: failing these just means "still catching up".
check pending "1 node syncProgress = 100.00" "$NODE_PROGRESS%" [ "$NODE_PROGRESS" = "100.00" ]
check pending "2 0 <= gap <= $MAX_BLOCK_GAP" "$GAP blocks" test "$GAP" -ge 0 -a "$GAP" -le "$MAX_BLOCK_GAP"
check pending "3 newest block age < ${MAX_LAG_SECONDS}s" "${DB_LAG}s" [ "$DB_LAG" -lt "$MAX_LAG_SECONDS" ]
(( advance > 0 )) || echo "SKIP  4 still advancing  (run with --advance 300)"

echo
if (( ${#faults[@]} )); then
  echo "RESULT: FAULT - failed check(s): $(IFS=';'; echo "${faults[*]}")"
  (( AHEAD_PERSISTED )) && echo "        db-sync has blocks the node doesn't: check for a node restart on an older DB," \
                               "a deep rollback, or db-sync pointed at another node's socket."
  exit 1
fi
if (( ${#pending[@]} )); then
  rate=""
  if (( advance > 0 )); then
    rate=", db-sync rate $(( (DB_BLOCK - first_block) * 60 / ($(date -u +%s) - first_epoch_s) )) blocks/min"
  fi
  age="$(( DB_LAG / 86400 ))d $(( DB_LAG % 86400 / 3600 ))h"; (( DB_LAG < 86400 )) && age="${DB_LAG}s"
  echo "RESULT: CATCHING UP - node at ${NODE_PROGRESS}%, db-sync $GAP blocks behind node, newest block $age old${rate}"
  exit 3
fi
if (( advance == 0 )); then
  echo "RESULT: UNCONFIRMED - at the tip on one sample; run with --advance 300 to confirm it is still moving"
  exit 4
fi
echo "RESULT: READY - db-sync caught up and advancing; Midnight may start"

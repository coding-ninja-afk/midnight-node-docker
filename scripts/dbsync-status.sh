#!/usr/bin/env bash
# Report cardano-db-sync progress against the local cardano-node tip and classify it as
# READY / CATCHING UP / FAULT using the criteria in RUNBOOK.md section 7. All times UTC.
#
# Usage:
#   scripts/dbsync-status.sh [--advance SECONDS] [--stack STACK] [--network NETWORK]
#     --advance 300        two samples 300 s apart (needed for READY; one sample = UNCONFIRMED)
#     --stack compose      the hand-built stack in compose-partner-chains.yml (default)
#     --stack tf:PREFIX    a Terraform-built stack: containers PREFIX-{cardano-node,postgres,
#                          cardano-db-sync}, e.g. tf:mn-preprod (infra/ output dbsync_readiness_check)
#     --network NAME       preprod (default) | preview | mainnet: selects cardano-cli's network magic
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
RETRIES="${DBSYNC_RETRIES:-3}"
RETRY_DELAY="${DBSYNC_RETRY_DELAY:-5}"

usage() { echo "usage: $0 [--advance SECONDS] [--stack compose|tf:PREFIX] [--network preprod|preview|mainnet]" >&2; exit 2; }
advance=0 stack=compose network=preprod
while [[ $# -gt 0 ]]; do
  case "$1" in
    --advance) advance="${2:-}"; [[ "$advance" =~ ^[0-9]+$ && "$advance" -gt 0 ]] || usage; shift 2 ;;
    --stack)   stack="${2:-}"; [[ "$stack" == compose || "$stack" =~ ^tf:[a-z0-9][a-z0-9-]*$ ]] || usage; shift 2 ;;
    --network) network="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
case "$network" in
  preprod) magic=(--testnet-magic 1) ;;
  preview) magic=(--testnet-magic 2) ;;
  mainnet) magic=(--mainnet) ;;
  *) usage ;;
esac

# Stack adapters: the same checks run against the compose stack or a Terraform-built one.
#   svc_running SVC / svc_exec SVC CMD... / svc_logs SVC   (SVC = cardano-node|postgres|cardano-db-sync)
if [[ "$stack" == compose ]]; then
  dc() { docker compose -f compose-partner-chains.yml "$@"; }
  svc_running() { [[ -n "$(dc ps --status running -q "$1" 2>/dev/null)" ]]; }
  svc_exec()    { local s="$1"; shift; dc exec -T "$s" "$@"; }
  svc_logs()    { dc logs --no-color --since "$LOG_WINDOW" "$1"; }
  where() { echo "compose service '$1'"; }
else
  prefix="${stack#tf:}"
  svc_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$prefix-$1" 2>/dev/null)" == true ]]; }
  svc_exec()    { local s="$1"; shift; docker exec -i "$prefix-$s" "$@"; }
  svc_logs()    { docker logs --since "$LOG_WINDOW" "$prefix-$1"; }
  where() { echo "container '$prefix-$1'"; }
fi
echo "# stack=$stack network=$network"

for svc in cardano-node postgres cardano-db-sync; do
  if ! svc_running "$svc"; then
    echo "error: $(where "$svc") is not running" >&2
    exit 2
  fi
done

# psql over the in-container socket; credentials never leave the container.
# shellcheck disable=SC2016  # $(cat ...) must expand inside the container, not here
psql_q() {
  svc_exec postgres sh -c \
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

  tip="$(svc_exec cardano-node cardano-cli query tip "${magic[@]}" --socket-path /ipc/node.socket)" \
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

faults=() pending=() warnings=()
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
# Read the logs first and check the read itself: a failed read (daemon error, missing container)
# or an empty window must never be scored as "0 errors".
if ! dblogs="$(svc_logs cardano-db-sync 2>&1)"; then
  echo "error: could not read logs of $(where cardano-db-sync): $(head -1 <<<"$dblogs")" >&2
  exit 2
fi
log_lines="$(grep -c . <<<"$dblogs" || true)"
errors="$(grep -ciE ':Error:|\bException\b' <<<"$dblogs" || true)"
if (( log_lines > 0 )); then
  check fault "5 no db-sync errors in last $LOG_WINDOW" "$errors error lines in $log_lines lines read" test "$errors" -eq 0
else
  # Nothing to read is not proof of a fault: if blocks are advancing (check 4), db-sync is working
  # and only its logging is quiet or redirected. It is a WARNING (RESULT can still be READY), and it
  # says plainly that "no errors" could not be confirmed. A real stall is check 4's FAULT.
  w="5 no db-sync log lines in last $LOG_WINDOW: absence of errors NOT confirmed"
  if (( advance > 0 )); then w="$w (blocks advanced $first_block -> $DB_BLOCK)"; else w="$w (single sample: run --advance to check progress)"; fi
  echo "WARN  $w"; warnings+=("$w")
fi
if (( advance > 0 )); then
  check fault "4 block_no advanced over ${advance}s" "$first_block@$first_ts -> $DB_BLOCK@$TS" [ "$DB_BLOCK" -gt "$first_block" ]
fi
# Readiness: failing these just means "still catching up".
check pending "1 node syncProgress = 100.00" "$NODE_PROGRESS%" [ "$NODE_PROGRESS" = "100.00" ]
check pending "2 0 <= gap <= $MAX_BLOCK_GAP" "$GAP blocks" test "$GAP" -ge 0 -a "$GAP" -le "$MAX_BLOCK_GAP"
check pending "3 newest block age < ${MAX_LAG_SECONDS}s" "${DB_LAG}s" [ "$DB_LAG" -lt "$MAX_LAG_SECONDS" ]
(( advance > 0 )) || echo "SKIP  4 still advancing  (run with --advance 300)"

echo
warn_note=""; (( ${#warnings[@]} )) && warn_note=" [WARNING: ${#warnings[@]}, see WARN lines above]"
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
  echo "RESULT: CATCHING UP - node at ${NODE_PROGRESS}%, db-sync $GAP blocks behind node, newest block $age old${rate}${warn_note}"
  exit 3
fi
if (( advance == 0 )); then
  echo "RESULT: UNCONFIRMED - at the tip on one sample; run with --advance 300 to confirm it is still moving${warn_note}"
  exit 4
fi
echo "RESULT: READY - db-sync caught up and advancing; Midnight may start${warn_note}"

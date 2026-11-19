#!/usr/bin/env bash
# Verify a Midnight node is importing and finalising blocks by taking timestamped (UTC)
# samples over its Substrate JSON-RPC. See RUNBOOK.md section 8 for the pass criteria.
#
# NOTE: written before the Midnight node was deployed; not yet run against a live node.
#
# Usage: scripts/midnight-height-check.sh [-n SAMPLES] [-i INTERVAL_S] [-o FILE]
#   env MIDNIGHT_RPC_URL (default http://127.0.0.1:9944)
# Exit: 0 = pass, 1 = fail, 2 = RPC unreachable / bad args.
set -euo pipefail

RPC="${MIDNIGHT_RPC_URL:-http://127.0.0.1:9944}"
SAMPLES=3
INTERVAL=60
OUT=""
BLOCK_TIME=6   # seconds, per docs.midnight.network/nodes ("Block time | 6 seconds")

while getopts "n:i:o:" opt; do
  case "$opt" in
    n) SAMPLES="$OPTARG" ;; i) INTERVAL="$OPTARG" ;; o) OUT="$OPTARG" ;;
    *) echo "usage: $0 [-n SAMPLES] [-i INTERVAL_S] [-o FILE]" >&2; exit 2 ;;
  esac
done
[[ "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -ge 3 ]] || { echo "error: -n must be >= 3" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 30 ]] || { echo "error: -i must be >= 30" >&2; exit 2; }

rpc() {  # $1=method $2=params-json
  curl -fsS --max-time 10 -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$1\",\"params\":${2:-[]}}" "$RPC" \
    | jq -e '.result' 2>/dev/null \
    || { echo "error: RPC $1 failed at $RPC" >&2; exit 2; }
}
hex2dec() { printf '%d' "$1"; }

# Minimum blocks per interval: half the slots, so normal missed slots don't trip it,
# but a stall of half the interval or longer does.
min_advance=$(( INTERVAL / BLOCK_TIME / 2 ))

declare -a best fin
fail=0
log() { echo "$1"; [[ -n "$OUT" ]] && echo "$1" >> "$OUT"; return 0; }

log "# midnight-height-check rpc=$RPC samples=$SAMPLES interval=${INTERVAL}s min_advance=$min_advance"
log "# ts_utc best finalized highest peers is_syncing"
for ((s = 0; s < SAMPLES; s++)); do
  (( s > 0 )) && sleep "$INTERVAL"
  ts="$(date -u +%FT%TZ)"
  # Plain assignments only: rpc() exits its subshell on error, and a bare
  # var="$(...)" propagates that status to set -e. Nesting it inside another
  # $(...) would swallow the failure and record a bogus height of 0.
  head_json="$(rpc chain_getHeader)"
  fin_hash="$(rpc chain_getFinalizedHead)"
  fin_json="$(rpc chain_getHeader "[$fin_hash]")"
  sync="$(rpc system_syncState)"
  health="$(rpc system_health)"
  best[s]="$(hex2dec "$(jq -r '.number' <<<"$head_json")")"
  fin[s]="$(hex2dec "$(jq -r '.number' <<<"$fin_json")")"
  highest="$(jq -r '.highestBlock // .currentBlock' <<<"$sync")"
  peers="$(jq -r '.peers' <<<"$health")"
  syncing="$(jq -r '.isSyncing' <<<"$health")"
  log "$ts ${best[s]} ${fin[s]} $highest $peers $syncing"

  if (( s > 0 )); then
    delta=$(( best[s] - best[s-1] ))
    if (( delta < min_advance )); then
      log "FAIL best block advanced $delta (< $min_advance) between samples $((s-1)) and $s"; fail=1
    fi
  fi
  (( peers >= 1 )) || { log "FAIL no peers at $ts"; fail=1; }
done

# Finality may trail by a few blocks, but must move over the whole run.
if (( fin[SAMPLES-1] <= fin[0] )); then
  log "FAIL finalized head did not advance (${fin[0]} -> ${fin[SAMPLES-1]})"; fail=1
fi
gap=$(( highest - best[SAMPLES-1] ))
log "# final gap to network highest: $gap blocks (at tip when <= 3, i.e. ~18 s)"

if (( fail )); then log "RESULT: FAIL"; exit 1; fi
log "RESULT: PASS"

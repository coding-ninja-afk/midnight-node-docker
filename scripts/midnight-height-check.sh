#!/usr/bin/env bash
# Classify a Midnight node as READY / CATCHING UP / FAULT from timestamped (UTC) samples of
# its Substrate JSON-RPC. Criteria and rationale: RUNBOOK.md section 8.2.
#
# NOTE: written before the Midnight node was deployed; tested against a mock RPC only
# (scripts/tests/run-tests.sh).
#
# Usage: scripts/midnight-height-check.sh [-n SAMPLES] [-i INTERVAL_S] [-o FILE]
#   env MIDNIGHT_RPC_URL (default http://127.0.0.1:9944)
#
# Exit codes (shared with scripts/dbsync-status.sh):
#   0 READY        at the network tip, not syncing, importing and finalising
#   1 FAULT        stalled, no peers, finality stuck, or not closing the gap to the tip
#   2 ERROR        RPC unreachable / bad arguments
#   3 CATCHING UP  importing fast enough and closing the gap, not at the tip yet
set -euo pipefail

RPC="${MIDNIGHT_RPC_URL:-http://127.0.0.1:9944}"
SAMPLES=3
INTERVAL=60
OUT=""
BLOCK_TIME=6     # seconds, per docs.midnight.network/nodes ("Block time | 6 seconds")
MAX_TIP_GAP=3    # blocks (~18 s) behind the network's highest block still counts as "at tip"

while getopts "n:i:o:" opt; do
  case "$opt" in
    n) SAMPLES="$OPTARG" ;; i) INTERVAL="$OPTARG" ;; o) OUT="$OPTARG" ;;
    *) echo "usage: $0 [-n SAMPLES] [-i INTERVAL_S] [-o FILE]" >&2; exit 2 ;;
  esac
done
[[ "$SAMPLES" =~ ^[0-9]+$ && "$SAMPLES" -ge 3 ]] || { echo "error: -n must be >= 3" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -ge 30 ]] || { echo "error: -i must be >= 30" >&2; exit 2; }
# Check the output file up front: a failed append mid-run would trip set -e and exit 1,
# which would be misread as FAULT.
if [[ -n "$OUT" ]] && ! { : >> "$OUT"; } 2>/dev/null; then
  echo "error: cannot write to output file '$OUT'" >&2; exit 2
fi

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

declare -a best fin high gapv sync_flag epoch_s
faults=()
log() { echo "$1"; [[ -n "$OUT" ]] && echo "$1" >> "$OUT"; return 0; }

log "# midnight-height-check rpc=$RPC samples=$SAMPLES interval=${INTERVAL}s min_advance=$min_advance"
log "# ts_utc best finalized highest gap peers is_syncing"
for ((s = 0; s < SAMPLES; s++)); do
  (( s > 0 )) && sleep "$INTERVAL"
  ts="$(date -u +%FT%TZ)"; epoch_s[s]="$(date -u +%s)"
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
  # highestBlock is the best block peers have announced. Missing/null = unknown, never "at tip".
  high[s]="$(jq -r '.highestBlock // -1' <<<"$sync")"
  # gapv: blocks behind the network; -1 is reserved for "unknown". A node can briefly be ahead
  # of what peers have announced (it just imported a block), so a known gap is clamped at 0.
  if (( high[s] < 0 )); then gapv[s]=-1
  elif (( high[s] < best[s] )); then gapv[s]=0
  else gapv[s]=$(( high[s] - best[s] )); fi
  peers="$(jq -r '.peers' <<<"$health")"
  sync_flag[s]="$(jq -r '.isSyncing' <<<"$health")"
  log "$ts ${best[s]} ${fin[s]} $( (( high[s] >= 0 )) && echo "${high[s]}" || echo unknown) $( (( gapv[s] >= 0 )) && echo "${gapv[s]}" || echo "?") $peers ${sync_flag[s]}"

  if (( s > 0 )); then
    delta=$(( best[s] - best[s-1] ))
    if (( delta < min_advance )); then
      log "FAULT best block advanced $delta (< $min_advance) between samples $((s-1)) and $s"
      faults+=("stalled")
    fi
  fi
  (( peers >= 1 )) || { log "FAULT no peers at $ts"; faults+=("no peers"); }
done

last=$(( SAMPLES - 1 ))
# Finality may trail by a few blocks, but must move over the whole run.
if (( fin[last] <= fin[0] )); then
  log "FAULT finalized head did not advance (${fin[0]} -> ${fin[last]})"; faults+=("finality stuck")
fi

# Ready = the node itself says it is not syncing AND it is within MAX_TIP_GAP of what peers report.
at_tip=0
if [[ "${sync_flag[last]}" == "false" ]] && (( gapv[last] >= 0 && gapv[last] <= MAX_TIP_GAP )); then
  at_tip=1
fi

# Behind the tip: the gap must be shrinking, or the node will never get there. (Within
# MAX_TIP_GAP but isSyncing=true is a node settling at the tip: CATCHING UP, not a fault.)
if (( !at_tip )) && (( gapv[0] >= 0 && gapv[last] > MAX_TIP_GAP )) && (( gapv[last] >= gapv[0] )); then
  log "FAULT not closing the gap to the network tip (${gapv[0]} -> ${gapv[last]} blocks behind)"
  faults+=("falling behind")
fi

if (( ${#faults[@]} )); then
  # Unique reasons, in first-seen order (a stall is reported once per interval above).
  log "RESULT: FAULT - $(printf '%s\n' "${faults[@]}" | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')"; exit 1
fi
if (( at_tip )); then
  log "RESULT: READY - at tip (${gapv[last]} behind highest ${high[last]}), not syncing, finalized ${fin[0]} -> ${fin[last]}"
  exit 0
fi

# Catching up: explain why not ready and estimate time to tip.
if (( gapv[last] < 0 )); then
  why="network highest block unknown (no sync target from peers)"
  eta=""
else
  why="${gapv[last]} blocks behind highest ${high[last]}, isSyncing=${sync_flag[last]}"
  closed=$(( gapv[0] - gapv[last] )); elapsed=$(( epoch_s[last] - epoch_s[0] ))
  eta=""
  (( closed > 0 && elapsed > 0 )) && eta=", ETA ~$(( gapv[last] * elapsed / closed / 60 )) min at $(( closed * 60 / elapsed )) blocks/min net"
fi
log "RESULT: CATCHING UP - $why$eta"
exit 3

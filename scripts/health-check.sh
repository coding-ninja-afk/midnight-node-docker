#!/usr/bin/env bash
# Option C: node health checker. Polls the stack on a configurable interval, evaluates the health
# conditions, writes a structured JSON report per cycle, and compares each report with the previous
# one to flag regressions.
#
# It reuses the existing checks rather than re-implementing them:
#   dbsync    scripts/dbsync-status.sh --json      (Cardano node + db-sync; RUNBOOK section 7)
#   midnight  scripts/midnight-height-check.sh -j  (Midnight RPC; RUNBOOK section 8.2)
#
# Usage: scripts/health-check.sh [options]
#   --interval SECONDS     time between cycles (default 300)
#   --count N              cycles to run; 0 = forever (default 1)
#   --out-dir DIR          where reports go (default ./health-reports); one file per cycle,
#                          report-<UTC>.json, plus latest.json (a copy of the newest)
#   --keep N               keep the newest N reports, delete older ones (default 288 = 1 day at 5 min)
#   --checks LIST          comma list of dbsync,midnight (default dbsync,midnight)
#   --stack STACK          passed to dbsync-status.sh (compose | tf:PREFIX; default compose)
#   --network NAME         passed to dbsync-status.sh (default preprod)
#   --dbsync-advance S     run dbsync-status.sh with --advance S (default 0: one sample per cycle;
#                          progress is then judged across reports instead)
#   --midnight-rpc URL     default $MIDNIGHT_RPC_URL or http://127.0.0.1:9944
#   --midnight-samples N   default 3      --midnight-interval S   default 30 (minimums of that check)
#   --stall-after S        a block count that did not move between two reports at least S seconds
#                          apart is a regression (default 120; db-sync ~6 blocks, Midnight ~20 expected)
#
# Exit code of the LAST cycle:
#   0 OK          every check READY and no regression
#   1 REGRESSED   a check is FAULT, or something got worse since the previous report
#   2 ERROR       a check could not run (or bad arguments / unwritable out-dir / dir locked)
#   3 NOT READY   catching up or unconfirmed, nothing got worse
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

interval=300 count=1 out_dir="./health-reports" keep=288 checks="dbsync,midnight" stack=compose network=preprod
dbsync_advance=0 mn_rpc="${MIDNIGHT_RPC_URL:-http://127.0.0.1:9944}" mn_samples=3 mn_interval=30 stall_after=120
usage() { sed -n '/^# Usage:/,/^# Exit code/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
num() { [[ "$2" =~ ^[0-9]+$ ]] || { echo "error: $1 must be a non-negative integer, got '$2'" >&2; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) num "$1" "${2:-}"; interval="$2"; shift 2 ;;
    --count) num "$1" "${2:-}"; count="$2"; shift 2 ;;
    --out-dir) out_dir="${2:-}"; shift 2 ;;
    --keep) num "$1" "${2:-}"; keep="$2"; shift 2 ;;
    --checks) checks="${2:-}"; shift 2 ;;
    --stack) stack="${2:-}"; shift 2 ;;
    --network) network="${2:-}"; shift 2 ;;
    --dbsync-advance) num "$1" "${2:-}"; dbsync_advance="$2"; shift 2 ;;
    --midnight-rpc) mn_rpc="${2:-}"; shift 2 ;;
    --midnight-samples) num "$1" "${2:-}"; mn_samples="$2"; shift 2 ;;
    --midnight-interval) num "$1" "${2:-}"; mn_interval="$2"; shift 2 ;;
    --stall-after) num "$1" "${2:-}"; stall_after="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "error: unknown option $1" >&2; usage ;;
  esac
done
(( keep >= 1 )) || { echo "error: --keep must be >= 1" >&2; exit 2; }
IFS=',' read -r -a CHECKS <<<"$checks"
for c in "${CHECKS[@]}"; do [[ "$c" =~ ^(dbsync|midnight)$ ]] || { echo "error: unknown check '$c' (dbsync, midnight)" >&2; exit 2; }; done
command -v jq >/dev/null || { echo "error: jq is required" >&2; exit 2; }

# Output dir: must be writable, and only one poller may write to it at a time.
if ! mkdir -p "$out_dir" 2>/dev/null || [[ ! -w "$out_dir" ]]; then echo "error: cannot write to out-dir '$out_dir'" >&2; exit 2; fi
exec 9>"$out_dir/.lock"
flock -n 9 || { echo "error: another health-check is already writing to '$out_dir'" >&2; exit 2; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# ---- comparison with the previous report (pure jq: $prev and $cur are whole reports) ------------
# shellcheck disable=SC2016  # jq program, not shell
COMPARE='
  def rank: {"READY":0, "UNCONFIRMED":1, "CATCHING_UP":2, "FAULT":3, "ERROR":3}[.] // 3;
  def last_sample($c): ($c.samples // []) | last;
  ($cur.generated_epoch - $prev.generated_epoch) as $dt
  | [ ($cur.checks | keys[]) as $k | select($prev.checks[$k] != null)
      | $prev.checks[$k] as $p | $cur.checks[$k] as $c
      | (if ($c.result | rank) > ($p.result | rank) or (($c.result | rank) == 3 and $c.result != $p.result)
           then {check: $k, kind: "regression", what: "status", from: $p.result, to: $c.result} else empty end),
        (if ($c.result | rank) < ($p.result | rank)
           then {check: $k, kind: "improvement", what: "status", from: $p.result, to: $c.result} else empty end),
        ( last_sample($p) as $ps | last_sample($c) as $cs | select($ps != null and $cs != null)
          | if $k == "dbsync" then
              (if $dt >= $stall and $cs.db_block <= $ps.db_block
                 then {check: $k, kind: "regression", what: "db-sync block did not advance between reports", from: $ps.db_block, to: $cs.db_block, seconds: $dt} else empty end),
              (if $cs.gap > 5 and $cs.gap > $ps.gap
                 then {check: $k, kind: "regression", what: "gap to the node grew", from: $ps.gap, to: $cs.gap} else empty end),
              (if $cs.lag_s >= 300 and $cs.lag_s > $ps.lag_s + 60
                 then {check: $k, kind: "regression", what: "newest block age grew", from: $ps.lag_s, to: $cs.lag_s} else empty end),
              (if $cs.sync_progress < $ps.sync_progress
                 then {check: $k, kind: "regression", what: "node sync progress went backwards", from: $ps.sync_progress, to: $cs.sync_progress} else empty end)
            else
              (if $dt >= $stall and $cs.best <= $ps.best
                 then {check: $k, kind: "regression", what: "best block did not advance between reports", from: $ps.best, to: $cs.best, seconds: $dt} else empty end),
              (if $dt >= $stall and $cs.finalized <= $ps.finalized
                 then {check: $k, kind: "regression", what: "finalized block did not advance between reports", from: $ps.finalized, to: $cs.finalized, seconds: $dt} else empty end),
              (if $ps.peers > 0 and $cs.peers == 0
                 then {check: $k, kind: "regression", what: "peers dropped to 0", from: $ps.peers, to: 0} else empty end),
              (if ($cs.gap // 0) > 3 and ($cs.gap // 0) > ($ps.gap // 0)
                 then {check: $k, kind: "regression", what: "gap to the network tip grew", from: $ps.gap, to: $cs.gap} else empty end)
            end )
    ]
  | {previous_report: $prev_file, previous_generated_at: $prev.generated_at, seconds_since_previous: $dt,
     regressions: map(select(.kind == "regression") | del(.kind)), improvements: map(select(.kind == "improvement") | del(.kind))}
'

run_cycle() {  # $1=cycle number; sets CYCLE_EXIT
  local n="$1" ts epoch report c f rc prev_file comparison overall
  ts="$(date -u +%FT%TZ)"; epoch="$(date -u +%s)"
  local checks_json="{}"
  for c in "${CHECKS[@]}"; do
    f="$work/$c.json"; rm -f "$f"
    case "$c" in
      dbsync)
        local args=(--stack "$stack" --network "$network" --json "$f"); (( dbsync_advance > 0 )) && args+=(--advance "$dbsync_advance")
        "$HERE/dbsync-status.sh" "${args[@]}" > "$work/$c.log" 2>&1; rc=$? ;;
      midnight)
        MIDNIGHT_RPC_URL="$mn_rpc" "$HERE/midnight-height-check.sh" -n "$mn_samples" -i "$mn_interval" -j "$f" > "$work/$c.log" 2>&1; rc=$? ;;
    esac
    # A check that crashed without writing JSON is still reported, as ERROR, with its output.
    if ! jq -e . "$f" >/dev/null 2>&1; then
      jq -n --arg c "$c" --argjson rc "$rc" --arg out "$(tail -5 "$work/$c.log")" \
        '{check: $c, result: "ERROR", exit_code: $rc, message: ("check produced no report: " + $out), samples: []}' > "$f"
    fi
    checks_json="$(jq -c --arg c "$c" --slurpfile r "$f" '. + {($c): $r[0]}' <<<"$checks_json")"
  done
  report="$(jq -n --arg at "$ts" --argjson epoch "$epoch" --argjson n "$n" --argjson interval "$interval" \
    --argjson checks "$checks_json" '{schema: 1, generated_at: $at, generated_epoch: $epoch, cycle: $n, interval_s: $interval,
                                      checks: $checks}')"
  # Compare with the previous report (latest.json); an unreadable one is noted, never fatal.
  # The previous report is validated ONCE and passed on as a value (or null): a corrupt latest.json
  # once made a later jq step fail and an empty report replace latest.json (caught by the tests).
  prev_file="$out_dir/latest.json"; local prev_json="null"
  if [[ -f "$prev_file" ]] && jq -e '.schema == 1 and (.checks | type == "object")' "$prev_file" >/dev/null 2>&1; then
    prev_json="$(cat "$prev_file")"
    comparison="$(jq -n --argjson cur "$report" --argjson prev "$prev_json" --arg prev_file "$(jq -r '.report_file // "latest.json"' <<<"$prev_json")" \
      --argjson stall "$stall_after" "$COMPARE")"
  elif [[ -f "$prev_file" ]]; then
    comparison='{"previous_report": null, "note": "previous latest.json unreadable or from another schema; not compared", "regressions": [], "improvements": []}'
  else
    comparison='{"previous_report": null, "note": "first report in this directory", "regressions": [], "improvements": []}'
  fi
  local name; name="report-$(date -u -d "@$epoch" +%Y%m%dT%H%M%SZ).json"
  # effective_result: a single-sample db-sync check can only say UNCONFIRMED (it cannot see progress);
  # if its block advanced since a previous report at least --stall-after seconds older, the
  # "still advancing" condition is confirmed across reports and the check is effectively READY.
  # The raw result stays in .result. overall = worst effective result.
  report="$(jq --argjson cmp "$comparison" --arg name "$name" --argjson prev "$prev_json" \
    --argjson stall "$stall_after" '
    .checks |= with_entries(
        .value.effective_result = (
          if .key == "dbsync" and .value.result == "UNCONFIRMED" and $cmp.previous_report != null
             and ($cmp.seconds_since_previous // 0) >= $stall
             and (((.value.samples // []) | last | .db_block) // 0) > ((($prev.checks.dbsync.samples // []) | last | .db_block) // 1e18)
          then "READY" else .value.result end)
        | if .value.effective_result != .value.result
            then .value.effective_note = "still advancing confirmed across reports (\($cmp.seconds_since_previous) s)" else . end)
    | .overall = ([.checks[].effective_result] as $r
        | if any($r[]; . == "FAULT") then "FAULT" elif any($r[]; . == "ERROR") then "ERROR"
          elif any($r[]; . == "CATCHING_UP") then "CATCHING_UP" elif any($r[]; . == "UNCONFIRMED") then "UNCONFIRMED" else "READY" end)
    | . + {report_file: $name, comparison: $cmp}' <<<"$report")"
  # Backstop: never write (or replace latest.json with) a report that failed to build.
  if ! overall="$(jq -er '.overall' <<<"$report" 2>/dev/null)"; then
    echo "$ts cycle=$n ERROR: could not build the report; nothing written, latest.json unchanged" >&2
    CYCLE_EXIT=2; return
  fi
  # Atomic writes: a reader never sees half a report.
  printf '%s\n' "$report" > "$out_dir/.$name.tmp" && mv -f "$out_dir/.$name.tmp" "$out_dir/$name"
  cp -f "$out_dir/$name" "$out_dir/.latest.tmp" && mv -f "$out_dir/.latest.tmp" "$out_dir/latest.json"
  # Rotation: newest $keep reports stay.
  find "$out_dir" -maxdepth 1 -name 'report-*.json' -printf '%f\n' | sort | head -n "-$keep" | while read -r old; do rm -f "$out_dir/$old"; done

  local nreg; nreg="$(jq '.comparison.regressions | length' <<<"$report")"
  echo "$ts cycle=$n overall=$overall $(jq -r '[.checks | to_entries[] | "\(.key)=\(.value.effective_result)" + (if .value.effective_result != .value.result then "(raw \(.value.result))" else "" end)] | join(" ")' <<<"$report") regressions=$nreg $(jq -r '[.comparison.regressions[] | "[\(.check): \(.what) \(.from) -> \(.to)]"] | join(" ")' <<<"$report") -> $out_dir/$name"
  if [[ "$overall" == FAULT ]] || (( nreg > 0 )); then CYCLE_EXIT=1
  elif [[ "$overall" == ERROR ]]; then CYCLE_EXIT=2
  elif [[ "$overall" == READY ]]; then CYCLE_EXIT=0
  else CYCLE_EXIT=3; fi
}

CYCLE_EXIT=2; n=0
while :; do
  n=$((n + 1))
  run_cycle "$n"
  (( count > 0 && n >= count )) && break
  sleep "$interval"
done
exit "$CYCLE_EXIT"

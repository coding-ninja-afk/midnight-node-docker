#!/usr/bin/env bash
# Tests for scripts/dbsync-status.sh (fake docker) and scripts/midnight-height-check.sh
# (mock RPC). Needs bash, jq, curl, python3. Takes about 70 s (Midnight cases run in parallel).
# Usage: scripts/tests/run-tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
WORK="$(mktemp -d)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$WORK"; }
trap cleanup EXIT

pass=0 fail=0
expect() {  # $1=name $2=expected exit $3=expected RESULT prefix $4=output file $5=actual exit [$6=extra grep]
  local ok=1
  [[ "$5" == "$2" ]] || ok=0
  grep -q "^RESULT: $3" "$4" || ok=0
  [[ -z "${6:-}" ]] || grep -q -- "$6" "$4" || ok=0
  if (( ok )); then
    echo "ok    $1  (exit $5, $(grep '^RESULT:' "$4"))"; pass=$((pass + 1))
  else
    local want="exit $2 / RESULT: $3"; [[ -n "${6:-}" ]] && want+=" / contains \"$6\""
    echo "FAIL  $1  expected $want, got exit $5:"; sed 's/^/        /' "$4"; fail=$((fail + 1))
  fi
}

# ---------- dbsync-status.sh ----------
tip()  { printf '{"block": %s, "epoch": 200, "slot": 1, "syncProgress": "%s"}\n' "$1" "$2"; }
row()  { printf '%s|1|200|2026-11-19T00:00:00Z|%s\n' "$1" "$2"; }   # block, lag seconds

dbsync_case() {  # $1=name $2=expected exit $3=RESULT prefix $4=extra grep $5...=script args; reads $D
  local out="$WORK/$1.out" rc
  PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" DBSYNC_RETRY_DELAY=0 \
    "$SCRIPTS/dbsync-status.sh" "${@:5}" > "$out" 2>&1; rc=$?
  expect "dbsync/$1" "$2" "$3" "$out" "$rc" "$4"
}
newcase() { D="$WORK/db-$1"; mkdir -p "$D"; }

newcase ready
{ row 1000 20; row 1003 15; } > "$D/db_rows"; { tip 1002 100.00; tip 1004 100.00; } > "$D/node_tips"
dbsync_case ready 0 "READY" "" --advance 1

newcase catching_up
{ row 500 64000000; row 600 63990000; } > "$D/db_rows"; { tip 900 54.46; tip 950 54.47; } > "$D/node_tips"
dbsync_case catching_up 3 "CATCHING UP" "node at 54.47%" --advance 1

newcase single_sample_at_tip
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"
dbsync_case single_sample_at_tip 4 "UNCONFIRMED" ""

newcase transient_ahead      # one reading with gap -32, then a sane one: retried, not a fault
{ row 1000 20; row 1000 20; } > "$D/db_rows"; { tip 968 100.00; tip 1001 100.00; } > "$D/node_tips"
dbsync_case transient_ahead 4 "UNCONFIRMED" "retry 1/2"

newcase persistent_ahead     # gap -32 on every retry: FAULT
{ row 1000 20; row 1000 20; row 1000 20; } > "$D/db_rows"; { tip 968 100.00; tip 968 100.00; tip 968 100.00; } > "$D/node_tips"
dbsync_case persistent_ahead 1 "FAULT" "still ahead after 3 readings"
if grep -q "^PASS  2 " "$WORK/persistent_ahead.out"; then echo "FAIL  dbsync/persistent_ahead_gap_check  negative gap reported as PASS"; fail=$((fail+1)); else echo "ok    dbsync/persistent_ahead_gap_check  (negative gap not shown as PASS)"; pass=$((pass+1)); fi

newcase persistent_ahead_while_syncing   # must not hide behind "catching up"
{ row 1000 9000; row 1000 9000; row 1000 9000; } > "$D/db_rows"; { tip 968 54.00; tip 968 54.00; tip 968 54.00; } > "$D/node_tips"
dbsync_case persistent_ahead_while_syncing 1 "FAULT" ""

newcase stalled
{ row 1000 20; row 1000 400; } > "$D/db_rows"; { tip 1000 100.00; tip 1000 100.00; } > "$D/node_tips"
dbsync_case stalled 1 "FAULT" "block_no advanced" --advance 1

newcase errors_in_logs
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"
echo '[db-sync-node:Error:151] runDbThread: Error SNErrDbSessionErr' > "$D/logs"
dbsync_case errors_in_logs 1 "FAULT" "1 error lines"

newcase logs_unreadable      # a failed log read must be an ERROR, never "0 errors"
{ row 1000 20; row 1003 15; } > "$D/db_rows"; { tip 1002 100.00; tip 1004 100.00; } > "$D/node_tips"
echo "No such container: midnight-preprod-cardano-db-sync-1" > "$D/logs_fail"
out="$WORK/logs_unreadable.out"; PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" DBSYNC_RETRY_DELAY=0 "$SCRIPTS/dbsync-status.sh" --advance 1 > "$out" 2>&1; rc=$?
if [[ $rc == 2 ]] && grep -q "could not read logs" "$out" && ! grep -q "^RESULT: READY" "$out"; then echo "ok    dbsync/logs_unreadable  (exit 2, not READY)"; pass=$((pass+1)); else echo "FAIL  dbsync/logs_unreadable exit $rc"; cat "$out"; fail=$((fail+1)); fi

newcase logs_empty_advancing # quiet logs but blocks advance: a WARNING, still READY
{ row 1000 20; row 1003 15; } > "$D/db_rows"; { tip 1002 100.00; tip 1004 100.00; } > "$D/node_tips"; : > "$D/logs"
dbsync_case logs_empty_advancing 0 "READY .*\[WARNING: 1" "WARN  5 no db-sync log lines .* NOT confirmed (blocks advanced 1000 -> 1003)" --advance 1

newcase logs_empty_stalled   # quiet logs AND no progress: FAULT (check 4), warning still shown
{ row 1000 20; row 1000 400; } > "$D/db_rows"; { tip 1000 100.00; tip 1000 100.00; } > "$D/node_tips"; : > "$D/logs"
dbsync_case logs_empty_stalled 1 "FAULT - failed check.s.: 4 block_no advanced" "WARN  5 no db-sync log lines" --advance 1

newcase service_down
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; echo postgres > "$D/down"
out="$WORK/service_down.out"; PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" "$SCRIPTS/dbsync-status.sh" > "$out" 2>&1; rc=$?
if [[ $rc == 2 ]] && grep -q "not running" "$out"; then echo "ok    dbsync/service_down  (exit 2)"; pass=$((pass+1)); else echo "FAIL  dbsync/service_down exit $rc"; cat "$out"; fail=$((fail+1)); fi

# Terraform-built stack: must query the mn-<env>-* containers via docker exec, never compose,
# and use the network's cardano-cli magic.
tf_case() {  # $1=name $2=expected exit $3=RESULT prefix $4=must-appear-in-calls $5=must-not-appear $6...=args
  local out="$WORK/$1.out" rc ok=1
  PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" DBSYNC_RETRY_DELAY=0 \
    "$SCRIPTS/dbsync-status.sh" "${@:6}" > "$out" 2>&1; rc=$?
  expect "dbsync/$1" "$2" "$3" "$out" "$rc" ""
  grep -qF -- "$4" "$D/calls" || ok=0
  [[ -z "$5" ]] || ! grep -qF -- "$5" "$D/calls" || ok=0
  local never=""; [[ -n "$5" ]] && never=", never \"$5\""
  if (( ok )); then echo "ok    dbsync/$1/targets  (calls include \"$4\"$never)"; pass=$((pass+1))
  else echo "FAIL  dbsync/$1/targets  calls were:"; sed 's/^/        /' "$D/calls"; fail=$((fail+1)); fi
}

newcase tf_preprod_ready
{ row 1000 20; row 1003 15; } > "$D/db_rows"; { tip 1002 100.00; tip 1004 100.00; } > "$D/node_tips"
tf_case tf_preprod_ready 0 "READY" "exec -i mn-preprod-postgres" "compose" --stack tf:mn-preprod --advance 1
if grep -qF -- "exec -i mn-preprod-cardano-node cardano-cli query tip --testnet-magic 1" "$D/calls"; then
  echo "ok    dbsync/tf_preprod_ready/magic  (--testnet-magic 1)"; pass=$((pass+1))
else
  echo "FAIL  dbsync/tf_preprod_ready/magic"; fail=$((fail+1))
fi

newcase tf_mainnet_magic
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"
tf_case tf_mainnet_magic 4 "UNCONFIRMED" "query tip --mainnet" "--testnet-magic" --stack tf:mn-mainnet --network mainnet

newcase tf_container_down
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; echo "-postgres" > "$D/down"
out="$WORK/tf_container_down.out"; PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" "$SCRIPTS/dbsync-status.sh" --stack tf:mn-preprod > "$out" 2>&1; rc=$?
if [[ $rc == 2 ]] && grep -q "container 'mn-preprod-postgres' is not running" "$out"; then echo "ok    dbsync/tf_container_down  (exit 2)"; pass=$((pass+1)); else echo "FAIL  dbsync/tf_container_down exit $rc"; cat "$out"; fail=$((fail+1)); fi

newcase compose_default_unchanged     # default target is still the hand-built compose stack
row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"
tf_case compose_default_unchanged 4 "UNCONFIRMED" "compose -f compose-partner-chains.yml exec -T postgres" "mn-" 

for bad in "--stack tf:" "--stack nope" "--network testnet"; do
  # shellcheck disable=SC2086  # word splitting of $bad is intended
  "$SCRIPTS/dbsync-status.sh" $bad >/dev/null 2>&1; rc=$?
  if [[ $rc == 2 ]]; then echo "ok    dbsync/bad_args '$bad'  (exit 2)"; pass=$((pass+1)); else echo "FAIL  dbsync/bad_args '$bad' exit $rc"; fail=$((fail+1)); fi
done

# ---------- health-check.sh (Option C): reports, comparison, regressions ----------
HC="$SCRIPTS/health-check.sh"
hc_ok() { echo "ok    health/$1  ($2)"; pass=$((pass+1)); }
hc_fail() { echo "FAIL  health/$1  $2"; sed 's/^/        /' "${3:-/dev/null}"; fail=$((fail+1)); }
# A previous report "N seconds ago" with the given check object (raw JSON).
plant_prev() {  # $1=out-dir $2=seconds ago $3=check name $4=check json
  mkdir -p "$1"; local e=$(( $(date +%s) - $2 ))
  jq -n --argjson e "$e" --arg c "$3" --argjson chk "$4" \
    '{schema: 1, generated_at: ($e | todate), generated_epoch: $e, cycle: 1, overall: $chk.result, report_file: "report-planted.json",
      checks: {($c): ($chk + {effective_result: $chk.result})}, comparison: {regressions: [], improvements: []}}' > "$1/latest.json"
}
hc_db() {  # $1=name; runs health-check (dbsync only) with fake docker on $D; out-dir $WORK/hc-$1
  PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" DBSYNC_RETRY_DELAY=0 "$HC" --checks dbsync --count 1 --out-dir "$WORK/hc-$1" > "$WORK/hc-$1.out" 2>&1
}
dbprev() { jq -nc --argjson b "$1" --arg r "${2:-UNCONFIRMED}" '{check: "dbsync", result: $r, exit_code: 4, samples: [{db_block: $b, gap: 0, lag_s: 20, sync_progress: 100, node_block: $b}]}'; }

newcase hc_first; row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"
hc_db first; rc=$?; R="$WORK/hc-first/latest.json"
if [[ $rc == 3 ]] && jq -e '.schema == 1 and .overall == "UNCONFIRMED" and .checks.dbsync.samples[0].db_block == 1000
     and (.checks.dbsync.checks | length) == 6 and .comparison.note == "first report in this directory"' "$R" >/dev/null \
   && [[ $(find "$WORK/hc-first" -name 'report-*.json' | wc -l) == 1 ]]; then hc_ok first_report "exit 3, JSON shape, 1 report + latest.json"
else hc_fail first_report "exit $rc" "$WORK/hc-first.out"; fi

newcase hc_confirmed; row 1030 20 > "$D/db_rows"; tip 1031 100.00 > "$D/node_tips"; plant_prev "$WORK/hc-confirmed" 600 dbsync "$(dbprev 1000)"
hc_db confirmed; rc=$?; R="$WORK/hc-confirmed/latest.json"
if [[ $rc == 0 ]] && jq -e '.overall == "READY" and .checks.dbsync.result == "UNCONFIRMED" and .checks.dbsync.effective_result == "READY"
     and (.comparison.regressions | length) == 0' "$R" >/dev/null; then hc_ok advance_confirmed_across_reports "1000 -> 1030 over 600 s: effective READY, exit 0"
else hc_fail advance_confirmed_across_reports "exit $rc" "$WORK/hc-confirmed.out"; fi

newcase hc_stalled; row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; plant_prev "$WORK/hc-stalled" 600 dbsync "$(dbprev 1000)"
hc_db stalled; rc=$?; R="$WORK/hc-stalled/latest.json"
if [[ $rc == 1 ]] && jq -e '.checks.dbsync.effective_result == "UNCONFIRMED"
     and any(.comparison.regressions[]; .what == "db-sync block did not advance between reports" and .from == 1000 and .to == 1000)' "$R" >/dev/null
then hc_ok stalled_across_reports "block 1000 -> 1000 over 600 s: regression, exit 1"; else hc_fail stalled_across_reports "exit $rc" "$WORK/hc-stalled.out"; fi

newcase hc_short; row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; plant_prev "$WORK/hc-short" 30 dbsync "$(dbprev 1000)"
hc_db short; rc=$?; R="$WORK/hc-short/latest.json"
if [[ $rc == 3 ]] && jq -e '(.comparison.regressions | length) == 0 and .checks.dbsync.effective_result == "UNCONFIRMED"' "$R" >/dev/null
then hc_ok too_soon_to_judge "no new block after only 30 s (< --stall-after 120): no regression, not confirmed"; else hc_fail too_soon_to_judge "exit $rc" "$WORK/hc-short.out"; fi

newcase hc_fault; row 1040 20 > "$D/db_rows"; tip 1041 100.00 > "$D/node_tips"; echo '[db-sync-node:Error:151] runDbThread: Error SNErrDbSessionErr' > "$D/logs"
plant_prev "$WORK/hc-fault" 600 dbsync "$(dbprev 1000 READY)"
hc_db fault; rc=$?; R="$WORK/hc-fault/latest.json"
if [[ $rc == 1 ]] && jq -e '.overall == "FAULT" and any(.comparison.regressions[]; .what == "status" and .from == "READY" and .to == "FAULT")' "$R" >/dev/null
then hc_ok status_regression "READY -> FAULT flagged, exit 1"; else hc_fail status_regression "exit $rc" "$WORK/hc-fault.out"; fi

newcase hc_down; row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; echo "-postgres" > "$D/down"
PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" "$HC" --checks dbsync --stack tf:mn-preprod --count 1 --out-dir "$WORK/hc-down" > "$WORK/hc-down.out" 2>&1; rc=$?
if [[ $rc == 2 ]] && jq -e '.overall == "ERROR" and (.checks.dbsync.message | test("mn-preprod-postgres.*not running"))' "$WORK/hc-down/latest.json" >/dev/null
then hc_ok check_error "postgres down: ERROR with the check's message, exit 2"; else hc_fail check_error "exit $rc" "$WORK/hc-down.out"; fi

newcase hc_corrupt; row 1000 20 > "$D/db_rows"; tip 1001 100.00 > "$D/node_tips"; mkdir -p "$WORK/hc-corrupt"; echo '{not json' > "$WORK/hc-corrupt/latest.json"
hc_db corrupt; rc=$?
if [[ $rc == 3 ]] && jq -e '.comparison.note | test("unreadable")' "$WORK/hc-corrupt/latest.json" >/dev/null
then hc_ok corrupt_previous "unreadable previous report noted, not fatal"; else hc_fail corrupt_previous "exit $rc" "$WORK/hc-corrupt.out"; fi

newcase hc_rotate; for i in 1 2 3; do row $((1000 + i * 10)) 20; done > "$D/db_rows"; for i in 1 2 3; do tip $((1001 + i * 10)) 100.00; done > "$D/node_tips"
PATH="$HERE/fake-docker:$PATH" FAKE_DIR="$D" "$HC" --checks dbsync --count 3 --interval 1 --keep 2 --out-dir "$WORK/hc-rotate" > "$WORK/hc-rotate.out" 2>&1; rc=$?
n=$(find "$WORK/hc-rotate" -name 'report-*.json' | wc -l); cyc=$(jq .cycle "$WORK/hc-rotate/latest.json")
if [[ $n == 2 && $cyc == 3 && $(grep -c 'cycle=' "$WORK/hc-rotate.out") == 3 ]]; then hc_ok polling_and_rotation "3 cycles at 1 s, --keep 2 left 2 reports, latest = cycle 3"
else hc_fail polling_and_rotation "reports=$n latest_cycle=$cyc exit=$rc" "$WORK/hc-rotate.out"; fi

mkdir -p "$WORK/hc-locked"; ( flock 9; sleep 5 ) 9>"$WORK/hc-locked/.lock" & lockpid=$!; sleep 0.5
"$HC" --checks dbsync --out-dir "$WORK/hc-locked" > "$WORK/hc-locked.out" 2>&1; rc=$?; wait "$lockpid" 2>/dev/null
if [[ $rc == 2 ]] && grep -q "already writing" "$WORK/hc-locked.out"; then hc_ok locked_out_dir "second poller on the same dir refused, exit 2"; else hc_fail locked_out_dir "exit $rc" "$WORK/hc-locked.out"; fi
"$HC" --out-dir /proc/no-such-dir > "$WORK/hc-ro.out" 2>&1; rc=$?
if [[ $rc == 2 ]] && grep -q "cannot write" "$WORK/hc-ro.out"; then hc_ok unwritable_out_dir "exit 2"; else hc_fail unwritable_out_dir "exit $rc" "$WORK/hc-ro.out"; fi
for bad in "--interval x" "--checks dbsync,foo" "--keep 0" "--bogus"; do
  # shellcheck disable=SC2086  # word splitting of $bad is intended
  "$HC" $bad --out-dir "$WORK/hc-bad" >/dev/null 2>&1; rc=$?
  if [[ $rc == 2 ]]; then hc_ok "bad_args '$bad'" "exit 2"; else hc_fail "bad_args '$bad'" "exit $rc"; fi
done

# Midnight through the mock RPC (each run takes ~60 s: 3 samples, 30 s apart); both in parallel.
hcport=18990; HCPIDS=()
mnprev() { jq -nc --argjson b "$1" --argjson f "$2" --arg r "$3" '{check: "midnight", result: $r, exit_code: 0, samples: [{best: $b, finalized: $f, highest: ($b + 1), gap: 1, peers: 8, is_syncing: false}]}'; }
plant_prev "$WORK/hc-mn-stalled" 600 midnight "$(mnprev 5000 4998 READY)"
plant_prev "$WORK/hc-mn-ready" 600 midnight "$(mnprev 900 890 CATCHING_UP)"
for m in stalled ready; do
  python3 -I "$HERE/mock_midnight_rpc.py" "$hcport" "$m" & HCPIDS+=($!); PIDS+=($!)
  ( sleep 1; "$HC" --checks midnight --midnight-rpc "http://127.0.0.1:$hcport" --count 1 --out-dir "$WORK/hc-mn-$m" > "$WORK/hc-mn-$m.out" 2>&1; echo $? > "$WORK/hc-mn-$m.rc" ) &
  HCPIDS+=($!); hcport=$((hcport + 1))
done
deadline=$(( $(date +%s) + 150 ))
for m in stalled ready; do while [[ ! -s "$WORK/hc-mn-$m.rc" ]] && (( $(date +%s) < deadline )); do sleep 1; done; done
rc=$(cat "$WORK/hc-mn-stalled.rc" 2>/dev/null); R="$WORK/hc-mn-stalled/latest.json"
if [[ "$rc" == 1 ]] && jq -e '.overall == "FAULT"
     and any(.comparison.regressions[]; .what == "status" and .from == "READY" and .to == "FAULT")
     and any(.comparison.regressions[]; .what == "best block did not advance between reports" and .from == 5000)
     and any(.comparison.regressions[]; .what == "finalized block did not advance between reports")' "$R" >/dev/null
then hc_ok midnight_regressions "mock stalled vs READY 600 s ago: status, best, finalized flagged, exit 1"; else hc_fail midnight_regressions "exit $rc" "$WORK/hc-mn-stalled.out"; fi
rc=$(cat "$WORK/hc-mn-ready.rc" 2>/dev/null); R="$WORK/hc-mn-ready/latest.json"
if [[ "$rc" == 0 ]] && jq -e '.overall == "READY" and (.comparison.regressions | length) == 0
     and any(.comparison.improvements[]; .from == "CATCHING_UP" and .to == "READY") and (.checks.midnight.samples | length) == 3' "$R" >/dev/null
then hc_ok midnight_improvement "mock ready vs CATCHING_UP: improvement only, exit 0"; else hc_fail midnight_improvement "exit $rc" "$WORK/hc-mn-ready.out"; fi

# ---------- midnight-height-check.sh ----------
port=18950
declare -A MODES=(
  [ready]="0 READY"                [catching_up]="3 CATCHING UP"   [syncing_flag]="3 CATCHING UP"
  [unknown_highest]="3 CATCHING UP" [stalled]="1 FAULT"            [falling_behind]="1 FAULT"
  [finality_stuck]="1 FAULT"       [ahead_of_highest]="0 READY"
)
declare -A EXTRA=( [catching_up]="ETA" [syncing_flag]="isSyncing=true" [unknown_highest]="highest block unknown"
                   [stalled]="stalled" [falling_behind]="falling behind" [finality_stuck]="finality stuck"
                   [ahead_of_highest]="0 behind highest" )
for mode in "${!MODES[@]}"; do
  python3 -I "$HERE/mock_midnight_rpc.py" "$port" "$mode" & PIDS+=($!)
  ( sleep 1; MIDNIGHT_RPC_URL="http://127.0.0.1:$port" "$SCRIPTS/midnight-height-check.sh" -n 3 -i 30 \
      > "$WORK/mid-$mode.out" 2>&1; echo $? > "$WORK/mid-$mode.rc" ) & PIDS+=($!)
  port=$((port + 1))
done
wait "${PIDS[@]: -1}" 2>/dev/null
deadline=$(( $(date +%s) + 150 ))   # 3 samples x 30 s plus slack
for mode in "${!MODES[@]}"; do
  while [[ ! -s "$WORK/mid-$mode.rc" ]]; do
    (( $(date +%s) < deadline )) || { echo 124 > "$WORK/mid-$mode.rc"; echo "RESULT: TIMEOUT" >> "$WORK/mid-$mode.out"; }
    sleep 1
  done
done
for mode in ready ahead_of_highest catching_up syncing_flag unknown_highest stalled falling_behind finality_stuck; do
  read -r rc_exp res_exp <<<"${MODES[$mode]}"
  expect "midnight/$mode" "$rc_exp" "$res_exp" "$WORK/mid-$mode.out" "$(cat "$WORK/mid-$mode.rc")" "${EXTRA[$mode]:-}"
done

# -o into a missing directory must be a usage error (2), never a FAULT (1).
out="$WORK/bad_output.out"
"$SCRIPTS/midnight-height-check.sh" -o "$WORK/no-such-dir/x.txt" > "$out" 2>&1; rc=$?
if [[ $rc == 2 ]] && grep -q "cannot write" "$out"; then echo "ok    midnight/unwritable_output  (exit 2)"; pass=$((pass+1)); else echo "FAIL  midnight/unwritable_output exit $rc"; cat "$out"; fail=$((fail+1)); fi

echo; echo "$pass passed, $fail failed"
(( fail == 0 ))

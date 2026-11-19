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

newcase logs_empty           # nothing to read in the window: cannot confirm "no errors"
{ row 1000 20; row 1003 15; } > "$D/db_rows"; { tip 1002 100.00; tip 1004 100.00; } > "$D/node_tips"; : > "$D/logs"
dbsync_case logs_empty 1 "FAULT" "0 error lines in 0 lines read" --advance 1

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

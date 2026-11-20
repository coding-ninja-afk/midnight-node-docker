#!/usr/bin/env bash
# Offline checks for monitoring/ (no running stack needed; uses the pinned images):
#   1. promtool check config  (prometheus.yml + rule files it loads)
#   2. promtool check rules   (syntax + lint)
#   3. promtool test rules    (unit tests, run 5 times: startup, catch-up, stalls, disk, failed scrapes, missing metrics)
#   4. amtool check-config    (Alertmanager routes, receivers, inhibitions)
#   5. dashboard: valid JSON, datasource uid matches provisioning, every PromQL expression parses
#   6. docker compose config  (compose file is valid)
#   7. with --mutations: break the rules on purpose and require the unit tests to fail
# Usage: monitoring/scripts/check.sh [--mutations]      Exit: 0 all passed, 1 a check failed
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
PROM_IMAGE="prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06"
AM_IMAGE="prom/alertmanager:v0.34.2@sha256:39d8bb3966c694a124428a3a88fbcffd40bd069129ecd47c059f8a3f17c55f3b"
failed=0
step() { echo; echo "== $1"; }
ok_or_fail() { if [[ $1 -eq 0 ]]; then echo "PASS"; else echo "FAIL"; failed=1; fi; }
promtool() { docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" -v "${2:-$PWD/prometheus}:/p:ro" -w /p/tests --entrypoint promtool "$PROM_IMAGE" "${@:3}"; }

step "promtool check config"
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool "$PROM_IMAGE" check config /etc/prometheus/prometheus.yml; ok_or_fail $?

step "promtool check rules"
docker run --rm -v "$PWD/prometheus:/p:ro" --entrypoint promtool "$PROM_IMAGE" check rules /p/rules/midnight-fno.rules.yml /p/rules/params-preprod.yml; ok_or_fail $?

step "promtool test rules (5 runs: rule-group ordering once made these flaky)"
rc=0; for run in 1 2 3 4 5; do
  if ! out="$(promtool x "$PWD/prometheus" test rules alerts.test.yml params-missing.test.yml 2>&1)"; then rc=1; echo "run $run FAILED:"; echo "$out" | head -40; break; fi
done; [[ $rc -eq 0 ]] && echo "5/5 runs passed ($(grep -cE '^ *- interval:' prometheus/tests/alerts.test.yml) + $(grep -cE '^ *- interval:' prometheus/tests/params-missing.test.yml) tests)"; ok_or_fail $rc

step "amtool check-config"
docker run --rm -v "$PWD/alertmanager:/a:ro" --entrypoint amtool "$AM_IMAGE" check-config /a/alertmanager.yml; ok_or_fail $?

step "dashboard"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
chmod 0755 "$tmp"   # the tools run as nobody inside their containers and must read these files
dash=grafana/dashboards/midnight-fno.json
want_uid="$(sed -n 's/^ *uid: *//p' grafana/provisioning/datasources/prometheus.yml)"
if jq -e . "$dash" >/dev/null; then
  bad_uid="$(jq -r --arg u "$want_uid" '[.. | objects | select(has("datasource")) | .datasource | objects | select(.uid != $u)] | length' "$dash")"
  echo "panels: $(jq '[.panels[] | select(.type != "row")] | length' "$dash"); datasource refs not '$want_uid': $bad_uid"
  # Every expression becomes a recording rule, so promtool parses it.
  { echo "groups:"; echo "  - name: dashboard-exprs"; echo "    rules:"
    jq -r '.panels[].targets[]?.expr' "$dash" | nl -ba | while read -r n e; do
      printf '      - record: dashboard:expr_%s\n        expr: %s\n' "$n" "$(jq -Rn --arg e "$e" '$e')"; done; } > "$tmp/dash-rules.yml"
  chmod 0644 "$tmp/dash-rules.yml"
  docker run --rm -v "$tmp:/d:ro" --entrypoint promtool "$PROM_IMAGE" check rules --lint=none /d/dash-rules.yml >/dev/null; rc=$?
  echo "expressions parsed: $(grep -c 'record:' "$tmp/dash-rules.yml") (promtool exit $rc)"
  [[ "$bad_uid" == 0 && $rc -eq 0 ]]; ok_or_fail $?
else ok_or_fail 1; fi

step "docker compose config"
docker compose -f compose.yml config -q; ok_or_fail $?   # passes without the git-ignored secret (as in CI)

if [[ "${1:-}" == "--mutations" ]]; then
  step "mutation test (each broken rule must make the unit tests fail)"
  copy() { rm -rf "$tmp/m"; cp -r prometheus "$tmp/m"; chmod -R a+rX "$tmp/m"; }
  # Control: the UNMODIFIED rules through the same copy + test path must pass. Otherwise a broken
  # harness (e.g. unreadable files) would make every mutation look "caught".
  copy
  if promtool x "$tmp/m" test rules alerts.test.yml params-missing.test.yml >/dev/null 2>&1; then echo "control     unmodified copy passes (harness OK)"
  else echo "CONTROL FAILED: the unmodified copy fails, so mutation results would be meaningless"; failed=1; fi
  mutate() {  # $1=label $2=old $3=new
    local m="$tmp/m"; copy
    python3 -I -c 'import sys,pathlib; p=pathlib.Path(sys.argv[1]); s=p.read_text(); assert sys.argv[2] in s; p.write_text(s.replace(sys.argv[2], sys.argv[3], 1))' \
      "$m/rules/midnight-fno.rules.yml" "$2" "$3" || { echo "SETUP-ERROR $1"; failed=1; return; }
    if promtool x "$m" test rules alerts.test.yml params-missing.test.yml >/dev/null 2>&1; then echo "NOT CAUGHT  $1"; failed=1
    else echo "caught      $1"; fi
  }
  mutate "catch-up pages as stale (no slot-rate condition)" 'expr: cardano:node_tip_age_seconds > 300 and cardano:node_slot_rate_10m <= 1' 'expr: cardano:node_tip_age_seconds > 300'
  mutate "falling behind treated as catching up (old 0.5 slots/s threshold)" 'expr: cardano:node_tip_age_seconds > 300 and cardano:node_slot_rate_10m <= 1' 'expr: cardano:node_tip_age_seconds > 300 and cardano:node_slot_rate_10m < 0.5'
  mutate "db-sync falling behind not paged (old 0.5 slots/s threshold)" 'expr: cardano:dbsync_tip_age_seconds > 600 and cardano:dbsync_slot_rate_10m <= 1' 'expr: cardano:dbsync_tip_age_seconds > 600 and cardano:dbsync_slot_rate_10m < 0.5'
  mutate "stale threshold 3000 s instead of 300" 'cardano:node_tip_age_seconds > 300 and cardano:node_slot_rate_10m <= 1' 'cardano:node_tip_age_seconds > 3000 and cardano:node_slot_rate_10m <= 1'
  mutate "db-sync catch-up after restart pages (no gap-closing check)" 'expr: cardano:dbsync_block_gap > 5 and cardano:dbsync_gap_closing_15m <= 0' 'expr: cardano:dbsync_block_gap > 5'
  mutate "midnight stall without for: (startup flap)" $'        expr: midnight:best_advance_5m < 25\n        for: 5m' $'        expr: midnight:best_advance_5m < 25\n        for: 0m'
  mutate "midnight finality alert removed" 'expr: midnight:finalized_advance_10m == 0' 'expr: midnight:finalized_advance_10m < 0'
  mutate "behind-tip ignores major sync" 'expr: midnight:blocks_behind > 20 and on (job, instance) max by (job, instance) (substrate_sub_libp2p_is_major_syncing) == 0' 'expr: midnight:blocks_behind > 20'
  mutate "failed scrapes not alerted" 'expr: up{job=~"cardano-node|cardano-db-sync|midnight-node|node-exporter"} == 0' 'expr: up{job=~"none"} == 0'
  mutate "missing node-exporter target not alerted" ' or absent(up{job="node-exporter"})' ''
  mutate "missing metric with a working scrape not alerted" $'               (cardano_db_sync_db_slot_height > 0)\n' $'               up\n'
  mutate "db-sync node_block_height not required" $'\n               and on (job, instance) cardano_db_sync_node_block_height' ''
  mutate "db-sync db_block_height not required" $'\n               and on (job, instance) cardano_db_sync_db_block_height' ''
  mutate "midnight finalized height not required" $'\n               and on (job, instance) substrate_block_height{status="finalized"}' ''
  mutate "midnight sync_target height not required" $'\n               and on (job, instance) substrate_block_height{status="sync_target"}' ''
  mutate "midnight major-syncing flag not required" $'\n               and on (job, instance) substrate_sub_libp2p_is_major_syncing' ''
  mutate "node-exporter metric check without the disk alerts' fstype filter" \
    $'node_filesystem_avail_bytes{mountpoint=~"/|/var/lib/docker", fstype!~"tmpfs|overlay|squashfs"}\n               and on (job, instance, mountpoint, device) node_filesystem_size_bytes{mountpoint=~"/|/var/lib/docker", fstype!~"tmpfs|overlay|squashfs"}' \
    $'node_filesystem_avail_bytes{mountpoint=~"/|/var/lib/docker"}\n               and on (job, instance, mountpoint, device) node_filesystem_size_bytes{mountpoint=~"/|/var/lib/docker"}'
  mutate "node-exporter size metric not required" $'\n               and on (job, instance, mountpoint, device) node_filesystem_size_bytes{mountpoint=~"/|/var/lib/docker", fstype!~"tmpfs|overlay|squashfs"}' ''
  mutate "disk page floor 1 GB instead of 12 GB" '< 12e9)' '< 1e9)'
  mutate "24 h disk prediction without the 3 h history guard" ' and node:chain_fs_history_seconds >= 10800' ''
  mutate "a db-sync slot of 0 counted as a real slot" '(cardano_db_sync_db_slot_height > 0) + scalar' 'cardano_db_sync_db_slot_height + scalar'
  mutate "params-missing alert removed" 'expr: absent(cardano:slot_unix_offset_seconds)' 'expr: absent(up)'
  mutate "first_response dropped from an alert" '          first_response: "Plan the disk growth today' '          first_responsex: "Plan the disk growth today'
fi

echo; if (( failed )); then echo "RESULT: FAIL"; exit 1; fi; echo "RESULT: PASS"

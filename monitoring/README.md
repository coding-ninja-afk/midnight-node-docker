# monitoring/: Prometheus, Alertmanager and Grafana for the Midnight PreProd FNO stack

Section 2 of the brief. It watches the live stack: cardano-node, cardano-db-sync, the host disk,
and midnight-node once it is deployed. It pages on **three operational problems**, and on
**monitoring that cannot see**.

```
cardano-node ──(127.0.0.1:12798, loopback only)──> cardano-node-metrics sidecar (:12799, node's netns)
cardano-db-sync :8080 ────────────────────────────┐            │
node-exporter :9100 (host /) ─────────────────────┼──> Prometheus ──> Alertmanager ──> webhook PLACEHOLDER
midnight-node :9615 (file_sd, when deployed) ─────┘      │
                                                         └──> Grafana (dashboard "Midnight FNO - PreProd")
```

## Run it

```bash
monitoring/scripts/init-secrets.sh                 # Grafana admin password, owned by uid 472, mode 0400
docker compose -f monitoring/compose.yml up -d
# UIs (127.0.0.1 only): Prometheus :9090, Alertmanager :9093, Grafana :3000 (user admin, password in
# monitoring/secrets/grafana_admin_password)
monitoring/scripts/check.sh --mutations           # offline checks; also run in CI
```

- **Images:** Prometheus v3.16.0, Alertmanager v0.34.2, Grafana 13.3.0, node-exporter v1.12.1,
  socat 1.8.1.1. Each is pinned by digest and was at least two weeks old when chosen.
- **Prometheus sizing:** it keeps 30 days or 5 GB of data, whichever is reached first.
- **The webhook is a placeholder** (`http://alert-receiver.invalid/placeholder`). `.invalid`
  never resolves, so **nothing is delivered** until a real receiver replaces it in
  `alertmanager/alertmanager.yml`. Alerts are visible in Alertmanager and Grafana meanwhile.
- **Why the sidecar:** cardano-node 11.0.1 serves metrics on 127.0.0.1 inside its container only
  (`PrometheusSimple suffix 127.0.0.1 12798`). The sidecar shares the node's network namespace and
  forwards the port, so the live node's config is not changed. **If the node container is
  recreated, restart the sidecar:**
  `docker compose -f monitoring/compose.yml restart cardano-node-metrics`.
  `MonitoringTargetDown` fires until you do.

### Adding Midnight

When midnight-node runs:
1. List it in `prometheus/targets/midnight-node.yml`:
   `- targets: ["midnight-node:9615"]`, labels `{ component: midnight-node }`.
2. Attach Prometheus to the node's network (`mn-preprod-internal` for the Terraform stack).
3. Prometheus picks the target up within a minute, with no restart.

Until then there are no Midnight series and **no Midnight alerts**. That's on purpose: a
non-deployed node must not page. Once the target is listed, a failed scrape or a missing metric
does page.

## Metrics used (inspected on the live stack, 2026-11-19/20)

| Source | Series | Notes |
|---|---|---|
| cardano-node | `cardano_node_metrics_slotNum_int` | Tip age = `time() - slot - 1655683200` (PreProd, `rules/params-preprod.yml`). Checked live: 7 s at the tip |
| cardano-db-sync | `cardano_db_sync_db_slot_height`, `db_block_height`, `node_block_height` | Gap to its node straight from the metrics |
| midnight-node | `substrate_block_height{status=best\|finalized\|sync_target}`, `substrate_sub_libp2p_is_major_syncing`, `substrate_import_queue_processed_total{result}` | Names read from a running 2.1.101 node (smoke stack) |
| node-exporter | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` | Chain data is on `/` here (`/var/lib/docker` also matched) |

## Alert design

**What pages, and why only these.** A Midnight validator must import and finalise blocks, and it
can only verify them against fresh Cardano data from db-sync. So:
1. **Cardano data stale:** `CardanoNodeTipStale`, `DbSyncStale`, `DbSyncBehindNode`.
2. **Midnight blocks or finality stalled:** `MidnightBlocksStalled`, `MidnightFinalityStalled`.
3. **Chain-data disk running out:** `DiskSpaceLow`. That nearly took this stack down: free space
   fell from 17 GB to 2.4 GB in about 3 hours during the first sync.

These signals are **not** alerts on their own:
- **Peer counts** are a symptom already covered by alerts 1 and 2, and they move around a lot
  (6 → 1 in a minute).
- **CPU and memory** have been steady with plenty of headroom.
- **Container restarts** happen by design after every reboot.

All of them are on the dashboard.

**Thresholds come from the chain's timing.** PreProd produces a block every ~20 s, so a 300 s gap
happens by chance about 3 times in 10 million: an old tip is a fault, not bad luck. Midnight
produces a block every 6 s, so fewer than 25 of the expected 50 blocks in 5 minutes means it is
not importing. These are the same numbers as the readiness checks in RUNBOOK sections 7 and 8.2,
so the pager and the manual check agree.

**Startup.** Rates and deltas need two samples in their window, so nothing evaluates in the first
minutes after Prometheus or a node (re)starts. `for:` covers the rest. The 24 h disk prediction
needs **3 hours of history**: on first deployment it predicted −471 GB from 4 minutes of data and
went pending, which is why that guard exists.

**Catch-up versus falling behind.** "Behind" is only acceptable while the tip age **shrinks**,
meaning a slot rate **above 1/s**. That's `CardanoNodeCatchingUp`: **info**, routed to nobody.
- **At or below 1/s while behind pages**, whether the node has stopped or is still progressing but
  slower than the chain.
- An earlier threshold of 0.5 let a node at 0.6 slots/s drift 16 minutes behind as "catching up"
  without paging. A test and a mutation now cover that case.
- db-sync closing its gap after a restart doesn't page, and neither does Midnight in major sync.
- **Live, 2026-11-20 12:17:** after a reboot, db-sync came back **9.5 hours behind** and caught up
  at up to 944 slots/s; the node peaked at 4.7. Nothing paged during the recovery.

**Rates use `deriv()`** (a linear fit) over 10 minutes. At the tip it measured **0.80–1.05
slots/s** live. `delta()` read 0.70–1.19, and only 0.23 from a partly filled window right after
Prometheus started. Readings below 1 at the tip are harmless: the stale alerts also require the tip
to be more than 300 s old, and it stayed between 11 and 185 s.

**A slot of 0 means unknown.** db-sync reports slot 0 for about 45 s after a restart. Without a
filter that read as a tip **4.4 years old**, plus a rate spike lasting the whole window. All slot
inputs ignore zeros (`> 0`). A slot that **stays** 0 is `MonitoringMetricsMissing`, not a fake
staleness page.

**Blind monitoring is an alert.** A failed scrape **removes** the series the staleness rules read,
so on its own a dead target would look like silence. Separate pages cover that:
- `MonitoringTargetDown` for `up == 0`
- `MonitoringTargetMissing` for a target missing entirely
- `MonitoringMetricsMissing` for a scrape that works but lacks the needed metric
- `MonitoringParamsMissing` when the network constants are not loaded

**Page on the cause.** Alertmanager inhibitions, tested live:
- a stale node suppresses the db-sync alerts
- stalled blocks suppress finality and behind-tip alerts
- a down target suppresses its missing-metrics alert

**One rule group.** Rules in a group run in order, so the alerts always read this evaluation's
recorded values. With two groups the unit tests were flaky (4 of 8 runs), because alerts sometimes
read the previous minute's values.

| Alert | Severity | Fires when | Routed to |
|---|---|---|---|
| CardanoNodeTipStale | page | tip > 300 s old **and** slot rate ≤ 1/s (not shrinking: stopped or falling behind), for 5 m | placeholder webhook |
| CardanoNodeCatchingUp | info | tip > 300 s old **and** slot rate > 1/s (shrinking), for 15 m | nobody (dashboard) |
| DbSyncStale | page | db-sync tip > 600 s old **and** slot rate ≤ 1/s, for 5 m | webhook (inhibited by node stale) |
| DbSyncBehindNode | page | gap > 5 blocks **and** not closing over 15 m, for 15 m | webhook (inhibited by node stale) |
| MidnightBlocksStalled | page | best block +< 25 in 5 m, for 5 m | webhook |
| MidnightFinalityStalled | page | finalized block +0 in 10 m, for 5 m | webhook (inhibited by blocks stalled) |
| MidnightBehindTip | warning | > 20 blocks behind the network while **not** major-syncing, for 10 m | webhook |
| DiskSpaceLow | page | < 10% **or** < 12 GB free, for 5 m | webhook |
| DiskWillFillWithin24h | warning | 6 h linear prediction < 0 in 24 h, with ≥ 3 h of history, for 30 m | webhook |
| MonitoringTargetDown | page | `up == 0`, for 5 m | webhook |
| MonitoringTargetMissing | page | no target for cardano-node / db-sync / node-exporter, for 10 m | webhook |
| MonitoringMetricsMissing | page | scraped but key metric absent: 30 m (cardano-node, may replay), 15 m (others) | webhook (inhibited by target down) |
| MonitoringParamsMissing | page | network constants not loaded, for 5 m | webhook |

## First response, per alert

Each alert also carries its first response in the `first_response` annotation, so it shows up in
Alertmanager and in the notification itself.

### CardanoNodeTipStale
1. `docker ps`, then `docker logs midnight-preprod-cardano-node-1`: has it crashed, is it
   restarting, or is it replaying the ledger?
2. Peers: `cardano_node_metrics_peerSelection_Hot_int`. 0 means network, firewall or DNS.
3. Is the disk full? Check `DiskSpaceLow`.
4. **Do not restart midnight-node**; it is not the cause.

### CardanoNodeCatchingUp
Informational. No action while the tip age falls. If it stops falling, `CardanoNodeTipStale` fires.

### DbSyncStale
1. `scripts/dbsync-status.sh` gives READY or FAULT and the reasons.
2. `docker logs midnight-preprod-cardano-db-sync-1`: DB errors, or node-socket errors? Socket
   errors right after a restart are expected for about a minute.
3. Is Postgres healthy? Its healthcheck states the reason.
4. Disk.

### DbSyncBehindNode
1. db-sync logs: slow inserts, DB errors, rollbacks?
2. Postgres load and disk (iowait, `DiskSpaceLow`).
3. `scripts/dbsync-status.sh --advance 300`.

### MidnightBlocksStalled
1. Is `substrate_import_queue_processed_total{result="verification_failed"}` rising, and do the
   node logs show db-sync or Postgres errors? Then it is the **Cardano data path** (see above).
   That is the failure seen in testing: best block stuck, network moving, peers dropping.
2. Peers = 0 means P2P or firewall.
3. `scripts/midnight-height-check.sh` gives READY, CATCHING UP or FAULT.

### MidnightFinalityStalled
1. Is it network-wide? Compare with another node or an explorer.
2. Look for GRANDPA and justification errors in the logs; check `substrate_finality_grandpa_round`.
3. Only this node: restart it once. Network-wide: escalate to the Midnight operators.

### MidnightBehindTip
Check, in order:
1. peers
2. import failures by result
3. host CPU and disk pressure

### DiskSpaceLow
1. `docker system df -v`: what is growing?
2. Free space safely: `docker image prune`, trim container logs. **Never `docker compose down -v`**,
   which deletes the chain data.
3. Grow the volume.
4. Under ~2 GB, stop db-sync cleanly before Postgres fills the disk.

### DiskWillFillWithin24h
Plan the disk growth today. Find the growth with `docker system df -v`.

### MonitoringTargetDown
1. Is the service itself down? Check `docker ps`.
2. cardano-node: restart the `cardano-node-metrics` sidecar after the node container is recreated.
3. Is Prometheus attached to the stack's network?

### MonitoringTargetMissing
Check `prometheus/prometheus.yml` and http://127.0.0.1:9090/targets, then reload
(`curl -XPOST http://127.0.0.1:9090/-/reload`).

### MonitoringMetricsMissing
1. cardano-node: is it replaying the ledger after a restart? Then wait.
2. Otherwise compare the target's `/metrics` with the names in `prometheus/rules`; an upgrade may
   have renamed a metric.

### MonitoringParamsMissing
Exactly one `params-<network>.yml` must be in `prometheus/rules/`. Reload Prometheus.

## Tests (`scripts/check.sh`)

`promtool test rules` runs **21 + 1 scenarios**, each checking **all 13 alerts** at every evaluation
time (expected ones with exact labels and annotations, everything else silent), 5 runs per check:

| Scenario | Expected |
|---|---|
| healthy steady state | nothing |
| **startup:** node replays 20 min without a slot metric; Midnight flat for 3 min after a restart | nothing |
| **startup:** Prometheus has one sample | nothing |
| **startup:** db-sync reports slot 0 for 2 min after a restart (seen live), then the real tip | nothing |
| db-sync keeps reporting slot 0 for 20 min | `MonitoringMetricsMissing`, **not** a fake 4-year-old `DbSyncStale` |
| **catch-up:** initial sync far behind at 20 slots/s; Midnight in major sync | `CardanoNodeCatchingUp` (info) only |
| **catch-up:** db-sync restarts 200 blocks behind and closes the gap | nothing, including inside the window where the gap is still > 5 |
| cardano-node stalls at the tip | `CardanoNodeTipStale` (15 m old at minute 45), then `DbSyncStale` too |
| db-sync stuck, node fine | `DbSyncStale` + `DbSyncBehindNode` (gap 120) |
| **falling behind:** node keeps progressing at 0.6 slots/s from the tip; db-sync follows | `CardanoNodeTipStale` (10 m old at minute 25, 16 m at 40), then `DbSyncStale`; **not** `CatchingUp` |
| **falling behind:** only db-sync, at 0.6 slots/s and 2 blocks/min against 3 | `DbSyncStale` + `DbSyncBehindNode` (gap 40) |
| Midnight cannot verify blocks (best stuck at 0, network moving) | `MidnightBlocksStalled` + `MidnightFinalityStalled` |
| Midnight finality stops, blocks continue | `MidnightFinalityStalled` |
| Midnight 100 blocks behind, not syncing | `MidnightBehindTip` (warning) |
| disk 1 GB/min from 30 GB | `DiskSpaceLow` at once; no prediction yet (< 3 h history) |
| disk steady fill over 5 h | quiet at 2 h, `DiskWillFillWithin24h` at 4 h |
| small disk, 11 GB of 100 GB (11%) | `DiskSpaceLow` (the 12 GB floor alone) |
| small disk, 13 GB of 100 GB | nothing |
| **failed scrape:** cardano-node down, its series vanish | `MonitoringTargetDown` (staleness rules cannot see it) |
| metric gone with a working scrape / no node-exporter target / Midnight not configured | `MonitoringMetricsMissing`, `MonitoringTargetMissing`; no Midnight alerts |
| cardano-node scraped without a slot for 40 min | `MonitoringMetricsMissing` after 30 min |
| params file not loaded (separate file) | `MonitoringParamsMissing` |

**Expected values were computed by hand,** not copied from promtool's output: 18h 16m 40s behind
during catch-up, 15 m and 40 m for the stalled node, 120 blocks for db-sync.

The script also checks:
- `promtool check config` and `check rules`
- `amtool check-config`
- that every dashboard expression parses, and that the dashboard's datasource uid matches
- `docker compose config`

**`--mutations`** breaks the rules on purpose, 16 ways, and requires the tests to fail each time.
A mutation whose pattern no longer applies is a setup error, never counted as caught.
A **control run** with the unmodified rules must pass first: the first version of the harness
failed on file permissions and made every mutation look "caught".

**Live checks (2026-11-20):**
- All targets are scraped.
- The rules load (24 rules + params).
- After an unattended host reboot (12:17 UTC), everything came back on its own, including the
  sidecar, and caught up without paging.
- Grafana serves the provisioned dashboard; the default `admin/admin` login is refused.
- A stopped sidecar fires `MonitoringTargetDown` and clears after restart
  (`evidence/monitoring-live-scrape-failure-2026-11-20.txt`).
- The inhibitions work (`evidence/monitoring-inhibition-2026-11-20.txt`).

## Dashboard

`grafana/dashboards/midnight-fno.json`, provisioned read-only:
- **Status tiles** that turn red at the alert thresholds: Cardano and db-sync tip age, db-sync gap,
  Midnight best block and blocks per 5 min, disk free, targets up, alerts firing.
- **Trends behind each alert:** tip age, slot rate, db-sync gap and queue, Cardano peers, Midnight
  heights and import results, disk with its 24 h prediction, scrape health.
- **A firing and pending alerts table.**

Midnight panels show NO DATA until a Midnight target is added.

## Not done yet

- A real receiver: PagerDuty, Opsgenie or Slack, replacing the placeholder.
- A dead-man's switch (an always-firing `Watchdog` alert to an external heartbeat), so a dead
  Prometheus or Alertmanager is noticed.
- Postgres metrics (postgres_exporter: connections, replication of the db-sync DB, bloat).
- Midnight-specific checks for validator duty (blocks authored in its slots), once the node runs
  as a validator.

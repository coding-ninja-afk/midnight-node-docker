# Midnight Network: DevOps take-home (PreProd FNO)

| Section | Where | Status |
|---|---|---|
| 1. Node setup (Cardano node + DB Sync on PreProd) | [`RUNBOOK.md`](RUNBOOK.md), [`compose-partner-chains.yml`](compose-partner-chains.yml), [`infra/live/preprod-midnight/`](infra/live/preprod-midnight/), [`evidence/`](evidence/) | Cardano node and DB Sync are synced and **READY**. Midnight node deployed; it **imported and finalized blocks** but has **not finished syncing** and is **paused** (details below) |
| 2. Monitoring and alerting | [`monitoring/`](monitoring/), summary below | Running against the live stack |
| 3. Automation (option C: node health checker) | [`scripts/health-check.sh`](scripts/health-check.sh), usage below | Polling, JSON reports, comparison with the previous report; 49 scenario tests; run live |
| 4. Security and key management | [`SECURITY.md`](SECURITY.md) | Written |
| 5. Infrastructure as code | [`infra/`](infra/) | Terraform + CI, green: [run 44578932929](https://github.com/coding-ninja-afk/midnight-node-docker/actions/runs/44578932929) |

## Section 1: status of the Midnight node

**Done and verified on PreProd, 2026-11-20 (UTC):**
- Cardano node and DB Sync caught up. DB Sync READY at 13:45:51
  (`evidence/dbsync-ready-2026-11-20-post-tls.txt`), which gated the Midnight start.
- midnight-node 2.1.101 deployed with Terraform (`infra/live/preprod-midnight`, RUNBOOK section 8.3).
  It reads Cardano data through a read-only Postgres role over verified TLS (`VerifyFull`).
- **It imported and finalized blocks:**

  | Time (UTC) | best block | finalized block | peers |
  |---|---|---|---|
  | 13:52:37 | 768 | 641 | 1 |
  | 13:54:37 | 14,792 | 14,587 | 9 |

  That is **14,802 blocks imported and verified against db-sync, with 0 verification failures**
  (`evidence/midnight-height-2026-11-20.txt`, `evidence/midnight-phase2-2026-11-20.txt`).

**Not done:**
- **The node has not finished syncing.** It reached about block 15,000 of ~3,501,600 (≈ 0.4%).
  The readiness check correctly reported **CATCHING UP**, not READY. It never reached the chain
  tip, so it has not been verified as an in-sync node, and it is not a validator: no keys are
  registered.
- **It is paused on purpose** (stopped 13:58:33 UTC, data kept). Its initial sync writes ~11 GB/h
  and needs ~110 GiB in total, but only 24 GB were free, on the filesystem that also holds Postgres
  and cardano-node. To resume: grow the disk, `docker start` the node and indexer, and re-add the
  monitoring target (RUNBOOK section 8.3, step 8).

## Section 2: alert design

Full detail, every threshold and each alert's first response: [`monitoring/README.md`](monitoring/README.md).
The rules are in `monitoring/prometheus/rules/midnight-fno.rules.yml` and are unit-tested with
`promtool`, including startup, catch-up and failed scrapes.

**Why these three.** A Midnight validator must import and finalise blocks, and it can only verify
them against fresh Cardano data from db-sync. So we page on:

1. **Stale Cardano data:** the node's tip is more than 300 s old and not catching up (stopped, *or*
   progressing slower than the chain), or db-sync is stale or behind its node.
   - *Why 300 s:* blocks come every ~20 s, so a 300 s gap happens by chance about 3 times in 10
     million.
   - *First response:* find which side stopped. For the node: process, peers, disk. For db-sync:
     `scripts/dbsync-status.sh`, Postgres health, logs. Don't restart Midnight; it isn't the cause.
2. **Stalled Midnight blocks or finality:** fewer than 25 of the expected 50 blocks in 5 minutes,
   or finality frozen for 15 minutes.
   - *First response:* if imports fail verification while db-sync errors show, it's the Cardano
     data path (the failure seen in testing). Peers at 0 means networking. Then run
     `scripts/midnight-height-check.sh`.
3. **Chain-data disk:** a page at under 10% or 12 GB free, and a warning when the 6-hour trend
   fills the disk within 24 hours.
   - *Why:* this nearly took the stack down during the first sync (17 GB to 2.4 GB in about
     3 hours).
   - *First response:* find what's growing, prune images and logs (never `down -v`), grow the
     volume.

**Signal over noise:**
- Catching up (behind, with the tip age shrinking) is informational, not a page. Falling further
  behind while still progressing **does** page.
- db-sync closing its gap after a restart doesn't page.
- The disk trend needs 3 hours of history. Without that guard, a fresh Prometheus predicted
  −471 GB and went pending within minutes.
- Alertmanager pages the cause, not each symptom: a stale node suppresses the db-sync alerts, and
  stalled blocks suppress the finality alert.
- Peers, CPU, memory and restarts are dashboard context only.

**Monitoring that cannot see is an alert too.** A failed scrape removes the very series the
staleness rules read. Separate pages cover:
- targets down
- targets missing entirely
- scrapes that succeed but lack the needed metric
- missing network constants

The webhook is a **placeholder** for now (`alertmanager.yml`): alerts are visible in Alertmanager
and Grafana, but nothing is delivered until a real receiver is configured.

## Section 3: node health checker (option C)

`scripts/health-check.sh` polls the stack on a configurable interval, evaluates its health
conditions, writes a **JSON report per cycle**, and **compares each report with the previous one**
to flag regressions. It reuses the two existing checks instead of re-implementing them; both gained
a `--json`/`-j` output for this:

| Check | Script | What it evaluates |
|---|---|---|
| `dbsync` | `scripts/dbsync-status.sh --json` | Cardano node and db-sync: caught up, gap, newest-block age, errors in the logs (RUNBOOK section 7) |
| `midnight` | `scripts/midnight-height-check.sh -j` | Midnight RPC: best and finalized blocks advancing, peers, gap to the network tip (RUNBOOK section 8.2) |

### Usage

```bash
scripts/health-check.sh                                   # one cycle, both checks, reports in ./health-reports
scripts/health-check.sh --count 0 --interval 300          # poll forever, every 5 min (e.g. as a systemd service)
scripts/health-check.sh --checks dbsync --count 2 --interval 130   # what produced evidence/health-check-2026-11-20/
```

| Option | Default | Meaning |
|---|---|---|
| `--interval S` | 300 | Seconds between cycles |
| `--count N` | 1 | Cycles to run; `0` = forever |
| `--out-dir DIR` | `./health-reports` | `report-<UTC>.json` per cycle, plus `latest.json` (a copy of the newest) |
| `--keep N` | 288 | Keep the newest N reports (one day at 5 min) |
| `--checks LIST` | `dbsync,midnight` | Which checks to run |
| `--stack`, `--network` | `compose`, `preprod` | Passed to `dbsync-status.sh` (`tf:mn-preprod` for a Terraform stack) |
| `--dbsync-advance S` | 0 | Give `dbsync-status.sh` its own `--advance S`. By default it takes one sample per cycle, and progress is judged across reports |
| `--midnight-rpc URL` | `$MIDNIGHT_RPC_URL` or `http://127.0.0.1:9944` | Midnight RPC endpoint (localhost only on this host) |
| `--midnight-samples N`, `--midnight-interval S` | 3, 30 | Samples per Midnight check (the minimums that check allows) |
| `--stall-after S` | 120 | Two reports at least S seconds apart with **no new block** is a regression. db-sync expects ~6 blocks in 120 s, and Midnight ~20 |

**Each report** (`schema: 1`) contains:
- `generated_at` (UTC) and `cycle`
- `overall`: the worst *effective* result
- per check:
  - the raw `result`, `exit_code` and `message`
  - its `samples` and individual `checks`
  - `effective_result`
- `comparison`:
  - the previous report and the seconds since it
  - `regressions[]` and `improvements[]`, each with `check`, `what`, `from` and `to`

**What counts as a regression** (compared with the previous report):
- **Status got worse:** READY → UNCONFIRMED → CATCHING_UP → FAULT/ERROR, or one failure state
  became the other.
- **db-sync:** its block did not advance between reports at least `--stall-after` seconds apart;
  the gap to the node grew above 5; the newest-block age grew past 300 s; or node sync progress
  went backwards.
- **Midnight:** the best or finalized block did not advance between reports; peers dropped to 0;
  or the gap to the network tip grew.

**One sample, confirmed across reports.** A single db-sync sample can only say UNCONFIRMED, because
it cannot see progress. If the block **advanced** since a previous report at least `--stall-after`
seconds older, the "still advancing" condition is confirmed and `effective_result` is READY. The
raw result stays in the report. Two reports only 30 s apart prove nothing either way: no
confirmation, and no regression.

**Exit code** (of the last cycle):

| Code | Meaning |
|---|---|
| 0 | READY, no regressions |
| 1 | a FAULT, or any regression |
| 2 | a check could not run, or bad arguments / unwritable or locked out-dir |
| 3 | catching up or unconfirmed, nothing got worse |

**Robustness:**
- Reports are written atomically, and only one poller may use an out-dir (`flock`).
- A check that crashes without output is recorded as ERROR, together with its output.
- An unreadable previous report is noted and skipped. It used to replace `latest.json` with an empty
  file: the tests caught that, and it's fixed.
- A cycle whose report cannot be built writes nothing and exits 2.

**Tested** with `scripts/tests/run-tests.sh` (49 scenarios, run in CI), against the fake `docker`
and the mock Midnight RPC:
- first report
- advance confirmed across reports
- db-sync stalled across reports
- too soon to judge
- READY → FAULT
- service down (ERROR)
- corrupt previous report
- 3 polling cycles with `--keep 2` rotation
- a locked out-dir and an unwritable out-dir
- bad arguments
- Midnight stalled against a READY report (status, best and finalized regressions)
- Midnight READY against a CATCHING_UP report (improvement only)

**Live run (2026-11-20):** cycle 1 UNCONFIRMED, then cycle 2 **READY** ("still advancing confirmed
across reports (130 s)"), exit 0, no regressions (`evidence/health-check-2026-11-20/`). The
Midnight check was not run live, because the node is paused (Section 1).

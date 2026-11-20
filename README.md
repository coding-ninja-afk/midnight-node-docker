# Midnight Network: DevOps take-home (PreProd FNO)

| Section | Where | Status |
|---|---|---|
| 1. Node setup (Cardano node + DB Sync on PreProd) | [`RUNBOOK.md`](RUNBOOK.md), [`compose-partner-chains.yml`](compose-partner-chains.yml), [`infra/live/preprod-midnight/`](infra/live/preprod-midnight/), [`evidence/`](evidence/) | Cardano node and DB Sync are synced and **READY**. Midnight node deployed; it **imported and finalized blocks** but has **not finished syncing** and is **paused** (details below) |
| 2. Monitoring and alerting | [`monitoring/`](monitoring/), summary below | Running against the live stack |
| 3. Automation (node health checker, option C) | [`scripts/`](scripts/) | `dbsync-status.sh`, `midnight-height-check.sh` + 33 scenario tests |
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

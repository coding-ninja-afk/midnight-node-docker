# RUNBOOK: Midnight PreProd node (FNO onboarding)

Audience: an engineer who knows Docker and Linux but has not run Midnight or Cardano before.
All paths are relative to the repo root. Run every command from the repo root.
**All times in this runbook, in the scripts, and in `evidence/` are UTC.**

## 1. Why the Cardano stack comes first

Midnight is a Cardano partner chain. The Midnight node does not talk to cardano-node directly.
It reads Cardano state (registrations, stake, governance) from **PostgreSQL filled by Cardano
DB Sync**. So the stack starts in a fixed order:

```
cardano-node ──(unix socket, volume cardano-ipc)──> cardano-db-sync ──(SQL)──> postgres
                                                                                   │
                                     midnight-node (section 8) <──(SQL over TLS)───┘
                                           │
                                           └──(ws RPC)──> midnight-indexer
```

The Midnight node cannot start usefully until DB Sync has caught up to the Cardano tip. If you
start it too early it fails with `No latest block on chain.`. A first sync takes **6+ hours**,
so start this part first and leave it running.

## 2. Versions

| Component        | Version / image                                 | Source |
|------------------|-------------------------------------------------|--------|
| cardano-node     | `ghcr.io/intersectmbo/cardano-node:11.0.1`      | Midnight DB Sync guide: "Use Cardano-db-sync 13.7.1.0 together with Cardano-node 11.0.1" |
| cardano-db-sync  | `ghcr.io/intersectmbo/cardano-db-sync:13.7.1.0` | same |
| postgres         | `postgres:17.12-bookworm`                       | same guide installs PostgreSQL 17 |
| midnight-node    | `midnightntwrk/midnight-node:2.1.101`           | full-node guide + support matrix (PreProd, ledger 9) |
| midnight-indexer | 4.4.101                                         | indexer release notes (pairs with node 2.1.101) |

> **Gotchas on versions**
> - The upstream `midnightntwrk/midnight-node-docker` repo is behind its own docs. Its
>   `compose-partner-chains.yml` pins db-sync 13.6.0.5 and postgres 15.3, and `.envrc`
>   defaults to the **preview** network. Use the table above, not the upstream defaults.
> - The node 2.1.101 release note says "If you run a node only on Preprod, keep running
>   v1.0.400 for now". The full-node and ledger 9 pages say PreProd moved to ledger 9 on
>   2026-11-09 and needs 2.1.101. The newer pages win, but confirm before deploying.
> - Indexer 4.4.101 needs a full re-index from genesis. It is not an upgrade from 4.3.x.

## 3. Host requirements

- Docker Engine with Compose v2.
- Midnight's cardano-node page (Preview/PreProd column): 16 GB RAM or more, 4+ cores,
  30,000 IOPS, 40 GB NVMe minimum, 100 Mbps. This host has 8 vCPU / 32 GB. Postgres is tuned
  for it in the compose file (`shared_buffers=2GB`, `effective_cache_size=8GB`).
- **Disk: plan for 80 GB or more free for the Cardano side alone.** Measured on 2026-11-19 at
  about 51% synced: postgres 12.1 GB, cardano-node 8.9 GB, db-sync ledger state 1.0 GB. A
  linear projection to 100% gives about 45 GB, and recent epochs are heavier. The Midnight node
  and indexer need space on top of that. Midnight publishes no figure for those.

## 4. Files in this repo

| Path                              | Purpose                                                       | Committed? |
|-----------------------------------|---------------------------------------------------------------|------------|
| `compose-partner-chains.yml`      | cardano-node, postgres, cardano-db-sync                       | yes |
| `scripts/init-secrets.sh`         | creates `secrets/postgres_{db,user,password}`, never overwrites | yes |
| `scripts/dbsync-status.sh`        | db-sync vs node: READY / CATCHING UP / FAULT (section 7)      | yes |
| `scripts/midnight-height-check.sh`| timestamped Midnight samples: READY / CATCHING UP / FAULT (section 8) | yes |
| `scripts/tests/run-tests.sh`      | 19 scenario tests for both checks (fake docker, mock RPC), about 70 s | yes |
| `secrets/`                        | DB credentials (mode 700/600)                                 | **no** (`.gitignore`) |
| `evidence/`                       | captured sync output                                          | yes |

How credentials are handled: Compose mounts each file in `secrets/` at `/run/secrets/<name>`.
Postgres reads them through `POSTGRES_*_FILE`, and the db-sync image reads `/run/secrets/postgres_*`
natively. No credential is in the compose file, in environment variables, or in `docker inspect`
output. No service publishes a host port.

## 5. First-time setup

```bash
# 1. Create DB credentials (db=cexplorer, user=postgres, random 32-hex password).
scripts/init-secrets.sh

# 2. Start the stack. Compose project name is fixed to "midnight-preprod" inside the file.
docker compose -f compose-partner-chains.yml up -d

# 3. Check it.
docker compose -f compose-partner-chains.yml ps
docker compose -f compose-partner-chains.yml logs -f --tail 50 cardano-db-sync
```

What you should see:
- `cardano-node` becomes `healthy` once its socket exists (allow up to 10 min after a restart
  while it replays its ledger).
- `postgres` becomes `healthy`. `cardano-db-sync` waits for this.
- db-sync logs `Insert ... Block: epoch N, slot S, block B` lines. While it is catching up it
  logs one every 10,000 blocks, plus a statistics block at each epoch boundary.

> **Do not rename the compose project or the volume keys.** The data lives in Docker volumes
> `midnight-preprod_{cardano-node-data,cardano-ipc,postgres-data,db-sync-state}`. A different
> name means new empty volumes and a sync from zero.

## 6. Monitoring sync progress

```bash
scripts/dbsync-status.sh                  # one sample: at best UNCONFIRMED
scripts/dbsync-status.sh --advance 300    # two samples 5 min apart: can say READY
watch -n 60 scripts/dbsync-status.sh      # live view
```

Each sample line is UTC-timestamped and shows the db-sync block, slot, epoch, block time and
`lag` (age of its newest block, seconds), then the node block, `syncProgress` and `gap` (node
block minus db-sync block). The last line is always one `RESULT:`.

Both check scripts (this one and `scripts/midnight-height-check.sh`) use the same results:

| Exit | RESULT | Meaning | What to do |
|------|--------|---------|------------|
| 0 | `READY` | caught up and still advancing | go to the next stage |
| 1 | `FAULT` | something is wrong: stalled, db-sync ahead of the node, errors, falling behind | investigate. Waiting won't fix it |
| 2 | (error) | could not query: service down, RPC unreachable | fix access, rerun |
| 3 | `CATCHING UP` | healthy and moving, not at the tip yet (shows the rate) | wait |
| 4 | `UNCONFIRMED` | at the tip on one sample (db-sync only) | rerun with `--advance 300` |

**Negative gap (db-sync "ahead" of the node).** The script reads db-sync *first* and the node
*second*. The node's block only grows, so a healthy reading always has gap ≥ 0. When a reading
shows a negative gap, the script retries it (3 readings, 5 s apart). If it stays negative, that
is a **FAULT**, even while the node is still syncing: db-sync holds blocks this node doesn't
have. Likely causes are a node restarted on an older database, a deep rollback, or db-sync
reading another node's socket.

While the node itself is syncing, db-sync keeps pace with it and the gap stays near zero. That
is reported as CATCHING UP, not a stall.

## 7. Before you start Midnight: how to confirm DB Sync has caught up

Run `scripts/dbsync-status.sh --advance 300`. It must print `RESULT: READY` (exit 0), which
means **all** of these hold:

| # | Check | Pass condition | If it fails |
|---|-------|----------------|-------------|
| 0 | db-sync not ahead of node | gap ≥ 0 after up to 3 readings | FAULT |
| 1 | node `syncProgress` | `100.00` | CATCHING UP |
| 2 | db-sync block vs node block | 0 ≤ gap ≤ 5 blocks | CATCHING UP |
| 3 | age of db-sync's newest block | under 300 s | CATCHING UP |
| 4 | still advancing | `block_no` higher after 300 s | FAULT |
| 5 | logs | no `Error`/`Exception` lines from db-sync in the last 15 min | FAULT |

### Why these thresholds

PreProd uses 1-second slots with an active-slot coefficient of 0.05. That means **one block
every 20 s on average**, with arrivals that are roughly random (Poisson). The numbers follow
from that:

- **Not the docs' `sync_percent >= 99`.** That query measures the share of chain *history*
  covered, not how *fresh* the data is. PreProd history is about 4.5 years, so 1% is about
  16 days of missing blocks, and even 99.99% is about 4 hours. We keep the docs' query for
  reference, but it is not the gate.
- **Check 1 (`syncProgress = 100.00`) is needed but not enough.** It is rounded to 2
  decimals, and 0.005% of 4.5 years is about 2 hours. So the node can show 100.00 while
  still about 2 h behind. Check 3 closes that gap.
- **Check 0 (never ahead) and the lower bound of check 2.** db-sync only learns blocks from
  this node, so it can't legitimately be ahead. The earlier version of the script only checked
  `gap <= 5` and read the node first, so a real problem (gap -32) passed as "fine". We retry
  before calling it a FAULT, because a 1 to 2 block rollback on the node can briefly put it
  behind what db-sync already wrote. Three readings 5 s apart is long enough for db-sync to
  apply the same rollback.
- **Check 2 (gap ≤ 5 blocks, about 100 s of chain).** At the tip, db-sync writes each block
  within about a second of the node receiving it. 5 blocks leaves room for a block arriving
  between the two reads, and for routine 1 to 2 block rollbacks (short forks are normal on
  Cardano). A gap that stays above 5 means db-sync cannot keep up.
- **Check 3 (newest block < 300 s old).** With one block per 20 s on average, the chance
  of a real 300 s gap is about e^-15 ≈ 3×10⁻⁷. An older tip therefore points to a fault (node
  or db-sync behind, or stuck), not bad luck. Tighter limits such as 60 s would fail on normal
  variance (e^-3 ≈ 5% of the time).
- **Check 4 (advances over 300 s).** It uses the same odds: about 15 blocks are expected, and
  zero is almost never chance. It catches a db-sync that has *just* stalled or crashed and
  still passes checks 1 to 3 on a single sample.
- **Check 5 (no errors in 15 min).** db-sync restarts itself after some failures (for
  example a lost DB connection) and can look healthy between crash loops. 15 min covers
  several restart cycles. Older errors from a recovery you already handled don't block you.

Midnight itself only acts on Cardano data that is `CARDANO_SECURITY_PARAMETER` (2160 on
PreProd) blocks deep, so these thresholds are stricter than Midnight strictly needs. That is on
purpose: the point is to prove the pipeline is healthy, not just that the data is deep enough.

## 8. Midnight node: prerequisites and verification

> **Not yet deployed.** This section is written ahead of the deployment from the Midnight docs.
> `scripts/midnight-height-check.sh` was tested against a mock RPC only (`scripts/tests/run-tests.sh`).

### 8.1 Prerequisites (from the docs, each one a gotcha)

- **TLS to Postgres is mandatory.** Node 2.1.101 "connects to the Cardano db-sync PostgreSQL
  database over TLS only" and ignores `ALLOW_NON_SSL`. The Postgres in
  `compose-partner-chains.yml` has no TLS yet, so add a server cert/key (`ssl=on`) first.
  That restarts Postgres; db-sync resumes on its own.
- **Use a read-only DB role, not the superuser.** The docs use a `midnight` user. Create one
  with `SELECT` on `cexplorer` and give its password to the node through a secret file.
- **Keep RPC private.** The docs say RPC binds to localhost by default and recommend
  `--rpc-methods Safe` behind a reverse proxy. The upstream repo's `--rpc-external --rpc-cors all`
  `--prometheus-external` is the opposite, so don't copy it. Only P2P (30333) should be public.
- PreProd settings: `CFG_PRESET=preprod`, `CARDANO_SECURITY_PARAMETER=2160`,
  `--chain .../res/preprod/chain-spec-raw.json`.

### 8.2 Verification: block height must advance across timestamped checks

A single "node is up" check proves nothing: a node can be up, peered and stuck. And "it is
advancing" is not "it is ready": a node importing old blocks advances quickly while still days
behind. We therefore **sample the block height at least 3 times, 60 s apart, with UTC
timestamps**, and classify the node:

```bash
# RPC is localhost-only, so run this on the node host (or through an SSH tunnel).
scripts/midnight-height-check.sh -n 3 -i 60 -o "evidence/midnight-height-$(date -u +%F).txt"
```

Each sample records `ts_utc best finalized highest gap peers is_syncing` from
`chain_getHeader`, `chain_getFinalizedHead`, `system_syncState` and `system_health`. `gap` is
`highestBlock - best`, where `highestBlock` is the best block peers have announced.

**Health checks.** Any failure is a FAULT (exit 1):

| Check | Pass condition | Why |
|---|---|---|
| best block advances | ≥ 5 blocks in every 60 s interval | Midnight makes a block every 6 s (10 per minute). Half leaves room for missed AURA slots (an offline validator skips its turn). Less than that means the node stalled for 30 s or more. |
| at least 3 samples | 2 intervals both advancing | One interval could be a burst right before a stall. Two in a row rules that out. |
| finalized head advances | higher at the end than at the start | GRANDPA finality can trail the best block by a few blocks, so it isn't checked per interval. If it never moves, finality is stalled even though blocks are being produced. |
| peers | ≥ 1 in every sample | No peers means any "progress" is only the node's own fork. |
| closing the gap | if more than 3 blocks behind, `gap` smaller at the end than at the start | A node that advances but slower than the network will never reach the tip. |

**Readiness.** With no faults, the result is **READY (exit 0)** only if, in the last sample,
`isSyncing` is `false` **and** `gap` ≤ 3 blocks (about 18 s). Otherwise it is **CATCHING UP
(exit 3)**, with the reason and an ETA from how fast the gap closed:
- far behind (`isSyncing=true`, large gap): normal during initial sync. Wait.
- within 3 blocks but `isSyncing=true`: the node is settling at the tip. Rerun shortly.
- `highestBlock` unknown: peers haven't given a sync target yet, so we can't claim it is at the tip.

Both signals are required because neither is enough alone. `isSyncing` can read `false` before
the node has learned the network's height, and a small gap means nothing if `highestBlock` is
stale. Only READY clears the node for validator duties. CATCHING UP is evidence that sync is
progressing, not that the node is ready.

Why UTC timestamps: cardano-node, db-sync, postgres and midnight-node all log in UTC, while
this host's local clock is UTC+2. Recording UTC (`date -u`) lets evidence samples line up
with container logs and with other operators' reports without conversion mistakes.

The first application-level health signal is that the node does **not** log
`No latest block on chain.` (which means DB Sync was not caught up).

## 9. Day-2 operations

```bash
# Stop cleanly. stop_grace_period gives node and postgres 120 s to flush.
docker compose -f compose-partner-chains.yml down       # without -v. -v DELETES the chain data

# Restart one service
docker compose -f compose-partner-chains.yml restart cardano-db-sync

# psql shell (local socket inside the container, no password needed)
docker compose -f compose-partner-chains.yml exec postgres \
  sh -c 'psql -U "$(cat /run/secrets/postgres_user)" -d "$(cat /run/secrets/postgres_db)"'
```

All services use `restart: unless-stopped`, so they come back after a host reboot. **They can
only come back if `secrets/` still exists.** See section 10.

## 10. Recovery: secrets files lost (this happened on 2026-11-19)

**What happened.** `compose-partner-chains.yml` and `secrets/` were deleted from the working
directory while the stack was running. On the next restart (2026-11-17 16:22 UTC) Docker could
not bind-mount `secrets/postgres_db`. postgres and cardano-db-sync exited with code 127:
`OCI runtime create failed ... failed to fulfil mount request: open .../secrets/postgres_db: no
such file or directory`. cardano-node has no secret mounts, so it kept running. Inspect a
failed container with `docker inspect -f '{{.State.Error}}' <container>`.

Postgres only reads `POSTGRES_PASSWORD` when it initialises an **empty** data directory. A new
password file therefore does nothing on its own. The role inside the existing database still
has the old password, and db-sync cannot log in. Wiping the volume would throw away days of
sync. Instead, reset the password in place:

```bash
# 1. Recreate the compose file from git, then new secrets. The db/user values must match the
#    EXISTING database. Defaults are cexplorer/postgres. Pass others as: init-secrets.sh <db> <user>
scripts/init-secrets.sh

# 2. Start ONLY postgres. Keep db-sync down until the login works.
docker compose -f compose-partner-chains.yml up -d --no-deps postgres

# 3. Confirm the real role and database names. The official image trusts the in-container
#    unix socket, so no password is needed here.
docker compose -f compose-partner-chains.yml exec -T postgres psql -X -U postgres -d postgres -Atc \
  "SELECT rolname FROM pg_roles WHERE rolname !~ '^pg_'; SELECT datname FROM pg_database WHERE NOT datistemplate;"
#    If they differ from secrets/postgres_{user,db}, fix those files and repeat from step 2.

# 4. Set the role password from the secret file inside the container.
#    The password never appears in argv, shell history, or terminal output.
docker compose -f compose-partner-chains.yml exec -T postgres sh -c \
  'printf "%s\n" "\\set pw \`cat /run/secrets/postgres_password\`" \
     "ALTER ROLE \"$(cat /run/secrets/postgres_user)\" WITH PASSWORD :'"'"'pw'"'"';" \
   | psql -X -q -v ON_ERROR_STOP=1 -U postgres -d postgres'

# 5. Test the SCRAM login over the container's network address. 127.0.0.1 is "trust" and
#    would not exercise the password.
docker compose -f compose-partner-chains.yml exec -T postgres sh -c \
  'PGPASSWORD="$(cat /run/secrets/postgres_password)" psql -X -h "$(hostname -i | cut -d" " -f1)" \
     -U "$(cat /run/secrets/postgres_user)" -d "$(cat /run/secrets/postgres_db)" -Atc "select 1"'

# 6. Start the rest. db-sync continues from its last block.
docker compose -f compose-partner-chains.yml up -d
```

Result on 2026-11-19: the database had stopped at block 2,640,727 (epoch 164). db-sync resumed
from there within about 2 minutes, with no resync. See `evidence/dbsync-progress-2026-11-19.txt`.

**Prevention:** keep the contents of `secrets/` in a password manager or secrets store. It is
git-ignored on purpose, so git will not save you here.

## 11. Gotchas log

| Gotcha | Impact | Mitigation |
|--------|--------|------------|
| Upstream repo pins older db-sync/postgres and defaults to preview | wrong versions or network | pin from docs (section 2) |
| `secrets/` deleted → postgres/db-sync can't restart (exit 127) | outage of about 2 days | section 10. Back up secrets |
| `POSTGRES_PASSWORD` ignored on an existing volume | new secret alone doesn't restore login | `ALTER ROLE` in place (section 10) |
| `sync_percent >= 99` from the docs | can be about 16 days behind | 5-point check (section 7) |
| node `syncProgress` rounds to 2 decimals | "100.00" can be about 2 h behind | block-age check (section 7) |
| db-sync is capped by cardano-node's own sync | looks like a db-sync stall | compare with node `syncProgress` |
| midnight-node 2.1.101 requires TLS to Postgres | node can't read Cardano data | enable `ssl=on` before Midnight (section 8.1) |
| upstream repo exposes RPC/metrics externally | RPC abuse | keep RPC on localhost (section 8.1) |
| Disk headroom | 17 GB free vs about 20+ GB still needed | grow the disk before 100% (section 3) |
| `docker compose down -v` | deletes all chain data | never use `-v` here |

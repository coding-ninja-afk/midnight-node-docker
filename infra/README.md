# infra/: Midnight FNO stack as code (Terraform, Docker provider)

An **outline model** of the stack built by hand in [`RUNBOOK.md`](../RUNBOOK.md): cardano-node,
cardano-db-sync with PostgreSQL, midnight-node and the Midnight indexer. One codebase serves
Preview, PreProd and Mainnet; only `envs/<network>.tfvars` changes.

Target: the [kreuzwerker/docker](https://registry.terraform.io/providers/kreuzwerker/docker)
provider. It mirrors the live stack exactly, and `plan` and the tests run in CI without cloud
credentials. Evidence of deployability is a clean `terraform plan` for all three networks; nothing
here has been applied (see "What is verified").

## Architecture

```
                    internet (P2P only)
             3001/tcp │               │ 30333/tcp
     ┌────────────────▼─┐          ┌──▼───────────────────┐   net mn-<env>-p2p  (egress)
     │ cardano-node     │          │ midnight-node        │── 127.0.0.1:9944 RPC (Safe methods)
     │ 11.0.1           │          │ 2.1.101  uid 10001   │
     └──┬───────────────┘          └──▲──────────┬────────┘
  vol ipc │ node.socket    SQL, TLS    │          │ ws://midnight-node:9944
     ┌──▼───────────────┐  verify-full │          │ 9615 metrics (internal only)
     │ cardano-db-sync  │──▶┌──────────┴──┐       │       net mn-<env>-internal
     │ 13.7.1.0         │   │ postgres 17 │       │       (internal=true: no egress,
     └──────────────────┘   │ ssl=on      │       │        no published ports)
                            └─────────────┘  ┌────▼──────────────────┐
                                             │ indexer-standalone    │── 127.0.0.1:8088 GraphQL
                                             │ 4.4.101, SQLite /data │   net mn-<env>-edge
                                             └───────────────────────┘   (no outbound NAT)
 Volumes (mn-<env>-*): cardano-node-data, cardano-node-ipc, postgres-data,
 cardano-db-sync-state, midnight-node-data, midnight-indexer-data
 Secrets: files under var.secrets_dir on the Docker host, bind-mounted read-only (paths in state, never values)
```

| Component | Networks | Published | Talks to |
|---|---|---|---|
| cardano-node | p2p | `0.0.0.0:3001` | Cardano peers |
| postgres | internal | **none** | n/a |
| cardano-db-sync | internal (+p2p if `dbsync_allow_egress`) | none | node socket (volume), postgres |
| midnight-node | p2p, internal | `0.0.0.0:30333`, `127.0.0.1:9944` | peers, postgres (TLS) |
| indexer | internal, edge | `127.0.0.1:8088` | midnight-node ws |

## Layout

```
infra/
├── versions.tf            terraform ~> 1.17.0, docker provider = 4.7.0 (+ .terraform.lock.hcl, 4 platforms)
├── backend.tf             backend "s3" {} with use_lockfile; envs/<env>.s3.tfbackend (stub)
├── main.tf                module wiring and start-up order
├── variables.tf           typed, validated inputs (incl. the phase-2 gate)
├── outputs.tf             readiness commands, endpoints, container_specs (for tests)
├── envs/<env>.tfvars      everything that differs per network
├── modules/               network, postgres, cardano-node, cardano-db-sync, midnight-node, midnight-indexer
├── tests/                 terraform test suites (mock provider)
├── checkov/               custom policies CKV2_MN_1..3
└── scripts/               check-order.sh, mutation-test.sh
```

Every module has `versions.tf` (provider range `>= 4.6.0, < 5.0.0`), `variables.tf`, `main.tf` and
`outputs.tf`, and takes a shared `common` object (name prefix, labels, log options). Adding a
component means adding a module and one block in `main.tf`.

## Run it locally

Prerequisites: Terraform 1.17.x, Docker (for `plan`; tests need no daemon), Python 3 with
`checkov==3.4.5`, and tflint v0.66.0 (or its container image).

```bash
cd infra
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf   # git-ignored stub
terraform init

terraform fmt -check -recursive
terraform validate
tflint --recursive        # or: docker run --rm -v "$PWD:/data" -w /data ghcr.io/terraform-linters/tflint:v0.66.0 --recursive
checkov --config-file .checkov.yaml
for e in preview preprod mainnet; do terraform test -var-file=envs/$e.tfvars; done
scripts/check-order.sh
scripts/mutation-test.sh preprod
scripts/smoke-test.sh --midnight auto -o ../evidence/smoke-test-$(date -u +%F).txt   # real containers, see "Smoke test"
terraform plan -var-file=envs/preprod.tfvars
```

Results on 2026-11-19 (provider 4.7.0): fmt, validate, tflint and checkov clean. 17/17 tests pass
in each of the three environments. The ordering check passes 7/7. The mutation test catches 7/7.
Each plan is `20 to add, 0 to change, 0 to destroy`.

> Never `apply` on the host that runs the hand-built PreProd stack without checking disk space
> first. Names cannot collide (`mn-<env>-*` vs `midnight-preprod_*`, enforced by a test), but a
> second full stack doubles the disk usage.

## Per-environment variables (`envs/<network>.tfvars`)

| Variable | preview | preprod | mainnet |
|---|---|---|---|
| `network` (names, network magic) | preview (2) | preprod (1) | mainnet |
| `cardano_security_parameter` | 432 *(to confirm)* | 2160 (docs) | 2160 |
| `midnight_cfg_preset` / `midnight_chain_spec` | preview | preprod (docs) | mainnet *(to confirm)* |
| `midnight_extra_args` | `--pool-limit 35 --no-private-ip` | same (docs) | same |
| `midnight_bootnodes` | from the full-node guide *(to add)* | none needed (docs) | — |
| `indexer_network_id` | preview *(to confirm)* | preprod (ledger 9 page) | mainnet *(to confirm)* |
| `storage_gb` | 40/60/5/30/10 | 60/120/10/50/20 | 400/800/40/150/80 |
| `postgres_tuning` | 1 GB buffers | live stack's flags | db-sync guide's mainnet values |
| `images` | same digests across envs (support matrix lists node 2.1.101 everywhere) | ← | ← |
| `secrets_dir` | `/run/mn-preview-secrets` | `/run/mn-preprod-secrets` | `/run/mn-mainnet-secrets` |

Validation rejects: an unknown network, any image not pinned as `repo:tag@sha256:…` (or tagged
`latest`), storage below the per-network minimum, a relative `secrets_dir`, privileged host ports,
and phase 2 without evidence (next section).

## Start-up order and the two-phase start

```
network → cardano-node (wait: socket healthy) → postgres (wait: pg_isready) → cardano-db-sync
        → [phase-2 gate] → midnight-node volume-init (runs to completion) → midnight-node (wait: RPC healthy)
        → indexer
```

Short waits are Terraform's job (`depends_on` plus `wait = true` on healthchecks). The **hours-long
DB Sync catch-up is not**, so midnight-node and the indexer use an explicit two-phase start:

1. **Phase 1** (`midnight_start = false`, the default): everything is created. midnight-node and
   the indexer are created but **not started**.
2. Run the readiness check **against this Terraform stack** (it is a Terraform output):
   ```bash
   terraform output -raw dbsync_readiness_check
   # scripts/dbsync-status.sh --stack tf:mn-preprod --network preprod --advance 300
   ```
   The `--stack tf:<prefix>` mode queries the `mn-<env>-*` containers with `docker exec`, not the
   compose stack, and uses the network's `cardano-cli` magic. It is covered by
   `scripts/tests/run-tests.sh`. Repeat until it prints `RESULT: READY`.
3. **Phase 2**: apply with `midnight_start = true` and `dbsync_ready_at = "<UTC timestamp of that
   READY run>"`. Without a well-formed timestamp the plan is rejected. The timestamp is stored as
   the label `mn.dbsync-ready-at` on the midnight-node container as an audit trail.
4. Terraform starts midnight-node and **waits for its RPC healthcheck** (`system_health` via the
   image's `curl`). Only then does it create the indexer: the indexer module `depends_on` the
   node module, verified by `scripts/check-order.sh`.
5. Verify readiness with `terraform output -raw midnight_readiness_check` (the
   READY / CATCHING UP / FAULT check from RUNBOOK section 8.2).

After a host reboot, Docker restarts all containers in parallel: Terraform's ordering only
applies at create time, as does Compose's `depends_on`. db-sync exits with "Connection refused"
until Postgres is up, then recovers through `restart = unless-stopped` (seen on the live host on
2026-11-19: 2 restarts, under a second). The indexer retries the node for about 5 minutes
(`reconnect_max_attempts: 30` in its config), then exits and is restarted the same way.

**Shortening the DB Sync window on a rebuild**:
- Restore cardano-node's database from a **Mithril** snapshot (signature-verified, minutes
  instead of hours).
- Restore Postgres from a db-sync snapshot made by the **same db-sync version** (13.7.1.0), or
  from our own volume snapshots of node data + Postgres + db-sync ledger state, taken together
  with db-sync stopped.

db-sync then replays only the recent part of the chain. `cardano-node.wait_timeout` is a variable
because a restored node replays its ledger before the socket appears.

## Live deployment on the synced host: `live/preprod-midnight`

The full root above builds **every** component, a second Cardano stack included. On the host that
already runs the synced compose stack, that would mean a 6+ hour resync, about 60 GB of extra disk
(30 GB were free), and readiness evidence that would not apply to the new stack. So Midnight was
deployed with a **second, Midnight-only root** that reuses the same modules, unchanged:

| | Full root (`infra/`) | `live/preprod-midnight` |
|---|---|---|
| Cardano node, Postgres, db-sync | created (`mn-<env>-*`) | **not managed**: the synced compose stack |
| Index pre-creation, midnight-node, indexer | modules, phase 2 | the **same modules**, phase 2 |
| Network to Postgres | own `mn-<env>-internal` | the stack's `midnight-preprod_default` (Postgres is `postgres` there) |
| Readiness gate | `--stack tf:mn-<env>` | `--stack compose`: the db-sync this node actually reads |
| State | S3 (stub) | local, git-ignored, until the bucket exists; no secret values |
| Host paths | `secrets_dir` var | `host.auto.tfvars` (git-ignored; `.example` committed) |

The two-phase gate, the target guard (`scripts/assert-same-target.sh`) and every module test still
apply. CI validates this root too. The procedure, step by step, is in RUNBOOK section 8.3.

## Secrets: what goes where, and what ends up in state

No secret value appears in Terraform config, variables, plan or state. Containers get **host file
paths**, mounted read-only. `upload {}` blocks are banned (their content is stored in state) by a
test and by checkov `CKV2_MN_2`. Secret env vars are always `*_FILE` variants, which is also
tested. midnight-node's DB URL has no password: sqlx (0.8.6, used by node 2.1.101) reads it from
`PGPASSFILE`. Certificate and host-name verification come from `SSL_ROOT_CERT` (the CA file).
The node ignores `sslmode`/`sslrootcert` in the URL, and without `SSL_ROOT_CERT` it would encrypt
without verifying (smoke tests M8, M10, M11).

Host contract under `var.secrets_dir`. In production this is a tmpfs filled at boot by the
secrets fetcher described in [`SECURITY.md`](../SECURITY.md):

| Path | Owner uid | Mode | Read by |
|---|---|---|---|
| `postgres/postgres_db`, `postgres_user`, `postgres_password` | any (root reads them) | 0600 | postgres entrypoint **as root**, cardano-db-sync (root) |
| `postgres/midnight_db_password` | **999** | 0600 | the init script, which runs **as uid 999** (creates the read-only role) |
| `postgres/tls/server.crt`, `server.key` | 999 | 0644 / 0600 | postgres (`ssl=on`). SAN must include `postgres` |
| `midnight/pgpass` (`postgres:5432:cexplorer:midnight:<pw>`) | 10001 | 0600 | midnight-node (sqlx ignores group/world-readable pgpass) |
| `midnight/postgres-ca.crt` | 10001 | 0644 | midnight-node (`sslmode=verify-full`) |
| `midnight/keys/{aura,grandpa,cross_chain}.seed`, `node.key` | 10001 | 0400 | only when `validator_keys_enabled`. **Caveat:** the node copies each seed, in plaintext, into its keystore, which is on the chain-data volume. The module sets no `--keystore-path` yet (tested on 2.1.101, SECURITY.md section 4) |
| `indexer/secret` (hex, 32 bytes) | 10001 | 0400 | indexer (`APP__INFRA__SECRET_FILE`) |
| `indexer/blockfrost_id` | 10001 | 0400 | indexer (a placeholder is fine if SPO stake data is not needed) |

Why owners matter, as measured by `scripts/smoke-test.sh` on 2026-11-19:
- **The three `*_FILE` secrets:** the official Postgres entrypoint reads them **as root**, then
  unsets the `_FILE` variables before dropping to uid 999. Operator-owned 0600 files initialise
  a fresh volume fine (check O1). An earlier version of this README said the opposite; that
  was an untested inference, and the test disproved it.
- **Files Postgres opens itself, as uid 999:** `tls/server.key` (Postgres also insists on owner
  999 and 0600) and `midnight_db_password`, which our init script reads as uid 999. If that file
  is unreadable, the init **still completes**: `cat` fails, psql carries on, and the `midnight`
  role is created with **no password**. This was fixed: the init script now aborts on an
  unreadable or empty file (smoke checks O2 and O3 PASS, `evidence/smoke-test-2026-11-19.txt`).

State still contains the plan-time configuration: names, image digests, ports, file **paths**.
It is still sensitive for an attacker mapping the host, so the S3 backend is encrypted,
versioned and TLS-only.

## Tests: what each one catches

`terraform test` uses `mock_provider "docker"`, so it runs in CI with no daemon, against
plan-time values (`output.container_specs`).

| Suite / check | Fails when… |
|---|---|
| `exposure`: postgres_not_reachable | Postgres publishes a port, joins another network, or the internal network allows egress |
| `exposure`: only_p2p_ports_are_public | anything but 3001/30333 is bound beyond 127.0.0.1, or the edge network NATs outbound |
| `exposure`: no_secret_values | a secret-looking env var is not `*_FILE`, a URL embeds a password, an `upload` block exists, or a host mount is writable |
| `exposure`: midnight_db_connection | the node is not the `midnight` role with `sslmode=verify-full`, Postgres lacks `ssl=on`, the node runs as root, has capabilities, or RPC is not `Safe` |
| `exposure`: images_pinned | an image is not digest-pinned or drifts from RUNBOOK section 2 versions |
| `exposure`: never_collides | a name lacks `mn-<env>-` or reuses the live `midnight-preprod_*` volumes |
| `startup_gate` (5 runs) | midnight or the indexer start in phase 1; the readiness command does not target this stack; phase 2 is accepted without or with a malformed timestamp; phase 2 does not wait on the node's healthcheck |
| `inputs` (6 runs) | storage below minimum, unpinned image, unknown network, relative secrets dir, privileged port are accepted |
| `scripts/check-order.sh` | the dependency graph loses node → db-sync → midnight → indexer (or gains a reverse edge) |
| `scripts/mutation-test.sh` | a deliberate mistake is **not** caught. It applies 7 (published Postgres port, password in URL, RPC on 0.0.0.0, ungated start, missing indexer dependency, secret via `upload`, unpinned image) |
| checkov `CKV2_MN_1..3` + secrets scan | Postgres publishes ports, `upload` used, privileged container, secret-like strings |
| `scripts/smoke-test.sh` (real containers, below) | the modules do not actually work: init, TLS, role rights, secret ownership, midnight-node start |
| `scripts/assert-same-target.sh` (tested locally on real saved plans: same target phase 1 and phase 2; missing secret; other checkout; other daemon; swapped plan; non-local endpoint; unprovisioned secrets) | a live apply would use a plan made for a different daemon, workdir or set of host paths, or would bind-mount a missing file |

### Smoke test (`scripts/smoke-test.sh`)

It applies the **real** `network`, `postgres` and `midnight-node` modules as a throwaway
`mn-smoke-*` stack, with its own state, random scratch secrets and a throwaway CA. It checks the
stack and destroys it on exit, falling back to removing `mn-smoke-*` resources directly if
`terraform destroy` fails. It refuses to start if any `mn-smoke-*` resource exists, so it can
never touch another stack.

| Group | Checks |
|---|---|
| P1–P11 | fresh init and role script; `ssl=on`/TLS 1.2+/SCRAM; `pg_hba` (midnight: TLS only); role has a password, no admin rights, read-only default; secret readability by uid 999 / 10001; TLS login as `midnight` with `verify-full` + pgpass; non-TLS refused; wrong host name refused; SELECT works on later tables; INSERT / CREATE refused |
| I0–I6 | index pre-creation: refuses without the schema; 11 exact definitions; safe rerun; INVALID leftover rebuilt; conflicting definition fails the apply; role still read-only |
| O1–O3 | the secret-ownership rules above; unreadable or empty role password aborts init |
| R1–R3 | after an aborted first init plus a restart, Postgres runs without the role and must stay **unhealthy** (missing / empty password file); control: valid setup is healthy |
| M1–M11 | volume-init ownership fix; node runs as uid 10001; RPC answers; logs in as `midnight` over TLS (server log); writes data as uid 10001; attempts no CREATE INDEX; runs no DDL; `VerifyFull`; a copy of the node is rejected for an untrusted CA and a host-name mismatch (with a control that logs in) |

Checks that score the *absence* of a log line (M6, M7, and the `authorized=0` in M10/M11) only
pass if the log was actually read: a failed or empty `docker logs` is reported as
`LOG_READ_FAILED`, never as "nothing found".

`--midnight auto` (the default) runs M1–M11 only if the Docker host has at least 4 GB free.
Otherwise **each one is reported as `SKIP … NOT VERIFIED: <reason>`**, the summary lists them,
and the exit code is 4 (INCOMPLETE) instead of 0. CI runs `--midnight require`: too little disk
is a setup error (exit 2), so a skip can never look like a pass there. Exit codes: 0 pass,
1 fail, 2 setup error, 4 incomplete.

The mutation test found one gap while this was being built: the first version of `CKV2_MN_1`
matched on the container name, which checkov cannot resolve (it is built from a local), so it
never fired. It now matches the literal network alias.

## CI/CD (`.github/workflows/infra.yml`)

- **Pull request** (paths `infra/**`, `scripts/**`):
  - `static`: fmt, validate, tflint, checkov.
  - `test`: `terraform test` for each env, the ordering check, and the mutation test on preprod.
  - `scripts`: shellcheck plus the readiness-script tests.
  - `plan` (needs all three): one plan per env against the runner's Docker daemon, uploaded as an
    artifact, summarised in the job summary and posted as one PR comment per env, updated in place.
- **Push to `main`**: the same jobs, plus the smoke test.
  - **Live** (`vars.TF_LIVE_TARGET == 'true'`): `plan-live` runs on the self-hosted target runner
    (labels `self-hosted`, `midnight-preprod`). It plans against the remote state **and the live
    Docker daemon**. Next to the saved plan it records the target with
    `scripts/assert-same-target.sh record`:
    - the daemon's unique ID and endpoint
    - the `infra/` workdir (the modules' `abspath()` bakes the checkout path into the plan)
    - every bind-mount host path in the plan
  - Then `apply`, behind the `preprod` **GitHub Environment** (required reviewers: see the
    settings below; not yet configured), runs on the
    same runner label. It first runs `assert-same-target.sh check`, which refuses to apply on any
    of these:
    - a different daemon or endpoint
    - a different workdir
    - a plan whose paths differ from the record
    - **any bind-mount path missing on this host.** Docker would otherwise silently create a
      missing secret file as an empty directory.

    Then it applies exactly that plan (Terraform also refuses a saved plan if the state changed
    since).
  - **No live target:** `apply` is a dry run that prints the PR-style plan. That plan was made on a
    hosted runner's empty daemon, for review only, and is never applied.
  - The live Docker endpoint, `vars.TF_DOCKER_HOST` (default: the runner's own socket), is set
    **only** on `plan-live` and on the live steps of `apply`. Hosted jobs never see it. Path checks
    need the runner to be on the Docker host, so a non-`unix://` endpoint is refused. The runner
    needs `docker`, `terraform` and `jq`.
- Credentials: OIDC only (`id-token: write` on plan/apply only). Defaults to `contents: read`.
  `pull-requests: write` only on plan. Every action is pinned to a commit SHA (verified against
  its tag with `git ls-remote`). Terraform, tflint and checkov versions are pinned. actionlint is clean.

Repository settings this relies on (not in code). **Status on 2026-11-20:**
- **Environment `preprod` with required reviewers: NOT configured yet.** The environment exists
  with no protection rules, so the dry-run `apply` in
  [run 44769819556](https://github.com/coding-ninja-afk/midnight-node-docker/actions/runs/44769819556)
  ran without waiting for approval. Until reviewers are added, the gate is in the workflow but not
  enforced.
- **Branch protection on `main`** requiring the `static`, `test`, `scripts` and `plan` checks:
  **NOT configured yet.**
- **The pull-request path has not run yet.** No PR has been opened, so the PR plan comment exists
  in the workflow but is unproven. The plans themselves do run on every push, into the job summary
  and artifacts.
- Variables `TF_STATE_ROLE_ARN` / `TF_STATE_REGION` once the state bucket exists.
- `TF_LIVE_TARGET=true`, a self-hosted runner with the label `midnight-preprod` that reaches the
  target daemon (declared for actionlint in `.github/actionlint.yaml`), and optionally
  `TF_DOCKER_HOST` for real applies.

**Workflow runs:**
- **Latest green at the time of writing:**
  [run 44769819556](https://github.com/coding-ninja-afk/midnight-node-docker/actions/runs/44769819556),
  commit `4287a84`. Every job passed: static checks, `terraform test` ×3, readiness scripts,
  smoke test, plans ×3 and the dry-run apply. `plan (preprod, live target)` is skipped because
  `TF_LIVE_TARGET` is not set.
- **First fully green run:**
  [run 44566731108](https://github.com/coding-ninja-afk/midnight-node-docker/actions/runs/44566731108),
  commit `0a8836c`, including the smoke test (36 checks, on GitHub's runner).
- **First run:** [run 44562587270](https://github.com/coding-ninja-afk/midnight-node-docker/actions/runs/44562587270),
  commit `6200f9a`, failed. The ordering check could not run `terraform graph` after
  `init -backend=false` (it had only worked locally because of a git-ignored backend override),
  and the smoke test caught the then-missing certificate verification (M8). Both are fixed.

Because the repo is public, pull requests from forks get a read-only token and no OIDC: their
plans still run and go to the artifact and job summary, but the PR-comment step is skipped.

## Provider version: 4.7.0 (with 4.6.0 as the fallback)

4.7.0 was released on 2026-11-11, 8 days before this was written. The rule was: use 4.7.0 if
compatibility checks pass, otherwise keep 4.6.0 and record why. The checks, run on 2026-11-19 on
copies pinned to each version:

| Check | 4.6.0 | 4.7.0 |
|---|---|---|
| init / validate / tflint | ok | ok |
| `terraform test` ×3 envs | 17/17 each | 17/17 each |
| `plan` ×3 envs | 20 to add | 20 to add |
| check-order.sh | ok | ok |
| planned resource values (`show -json`) | identical after normalising the checkout path | ← |

Release notes for 4.7.0 contain no breaking changes. "Suppress equivalent time duration" removes
perpetual diffs on healthcheck durations. **Decision: 4.7.0.** Modules accept `>= 4.6.0, < 5.0.0`,
so falling back is a one-line change in `versions.tf` plus `terraform init -upgrade`.

## What is verified, and what is not

Verified while building this (2026-11-19):
- Image contents, read from registry metadata without pulling:
  - midnight-node 2.1.101 ships `curl`, so the healthcheck works.
  - Its entrypoint does **not** drop root, hence `user = 10001` and the volume-init container.
  - Chain specs live under `/res/`.
  - indexer-standalone runs as uid 10001, stores SQLite in `/data`, and creates
    `/var/run/indexer-standalone/running`, which the healthcheck uses.
- Behaviour, from source at the release tags:
  - indexer `*_FILE` support.
  - midnight-node reads `DB_SYNC_POSTGRES_CONNECTION_STRING` via sqlx 0.8.6, which applies `PGPASSFILE`.
- Configuration and tests: validate, plans, tests, lint and policies on 4.6.0 and 4.7.0.

**Verified at runtime by the smoke test** (2026-11-19, `evidence/smoke-test-2026-11-19.txt`,
36 PASS / 0 FAIL / 0 SKIP):
- The Postgres module on a fresh volume: role script, `pg_hba`, `ssl=on`, and the read-only role's
  rights (which stay read-only after the index pre-creation).
- **Role password file:** an unreadable or empty `midnight_db_password` aborts the
  initialisation with a clear error (O2, O3).
- **Restart after a failed first init** (R1–R3):
  - When the init script aborts, initdb has already filled PGDATA. On restart the image skips
    initialisation and Postgres runs **without the `midnight` role**, and plain `pg_isready` says
    it is fine.
  - The module's healthcheck (`modules/postgres/files/healthcheck.sh`) also requires the role
    with its password, read-only default and grants. So such a container stays **unhealthy**
    (`UNHEALTHY: role 'midnight' does not exist`), and Terraform's `wait` fails the apply.
  - A valid setup reports healthy.
  - **Recovery:** fix the secret, then remove the data volume (nothing was synced into it yet)
    and apply again.
- **Index pre-creation** (phase-2 module `modules/midnight-db-indexes`, container
  `mn-<env>-midnight-db-indexes`, script `files/midnight-indexes.sh`):
  - It refuses to run without the db-sync schema.
  - It builds all 11 indexes with definitions identical to node 2.1.101, verified against every
    `CREATE INDEX` in the tag by `scripts/verify-index-defs.sh` (also in CI).
  - A rerun is a no-op. An INVALID leftover is rebuilt. A conflicting definition fails the apply
    through a postcondition (I0–I7).
- **midnight-node** (M1–M11):
  - It runs as uid 10001, logs in as `midnight` over TLS 1.3, finds its indexes, attempts no
    `CREATE INDEX`, runs no other DDL, and answers RPC.
  - **It verifies the database certificate** (`SSL mode: VerifyFull`, via `SSL_ROOT_CERT`).
  - A copy of the node container with only the TLS inputs changed is **rejected** for an
    untrusted CA (`invalid peer certificate: UnknownIssuer`) and for a host-name mismatch
    (`certificate not valid for name "172.19.0.2"; … only valid for DnsName("postgres")`).
  - In both cases the password file matched any host, so only TLS verification stopped the login.
    The same copy with the correct CA and host logs in (control, M9).

**Caveat:** the node's genesis tools run `ALTER TABLE … SET (autovacuum…)`, which needs table
ownership; the normal node run does not. `verify-index-defs.sh` lists that statement as a NOTE.

**Not verified at runtime** (check on the first real deployment):
- Whether db-sync without egress logs off-chain-fetch errors that would trip RUNBOOK check 5.
- The Preview/Mainnet preset names and indexer network IDs marked *to confirm*.
- Storage minimums other than PreProd cardano-node's 40 GB, which are estimates.

## Before production

- **HA without double-signing**: the validator stays single-active. Add a warm standby with
  **no keys** and fencing (SECURITY.md section 1). Run separate relay nodes for P2P.
- **Backups**: scheduled consistent snapshots of node + Postgres + db-sync state for fast
  rebuilds; a Mithril bootstrap path; tested restores.
- **Drift detection**: a scheduled `terraform plan -detailed-exitcode` that alerts on exit 2.
- **Cost controls**: right-size from monitoring (Section 2); storage alerts at 70/85% (this host
  nearly filled up during the first sync); tags or labels per environment.
- **Cloud target**: replace the Docker resources in each module with VM, disk and firewall
  resources. Variables, environment files and tests keep their shape. The phase-2 gate becomes
  a cloud-init step.
- **Secrets fetcher**: the KMS + secrets-manager → tmpfs flow from SECURITY.md produces the host
  contract above.
- **Keystore on tmpfs**: add `--keystore-path` on a tmpfs mount to `modules/midnight-node` before
  enabling `validator_keys_enabled`. Otherwise the seeds end up on the chain-data volume and in its
  snapshots.
- **Real state backend**: create the bucket (versioning, SSE-KMS, TLS-only policy) and an OIDC
  role scoped to `midnight/<env>/*`.

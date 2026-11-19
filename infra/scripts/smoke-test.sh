#!/usr/bin/env bash
# Docker smoke test for infra/. Applies the REAL network, postgres and midnight-node modules as a
# throwaway stack (mn-smoke-*, its own Terraform state, random scratch secrets and a throwaway CA),
# runs the checks below, and destroys everything on exit. It never touches other stacks: it refuses
# to start if any mn-smoke-* container, volume or network already exists.
#
# Usage: infra/scripts/smoke-test.sh [--midnight auto|require|skip] [-o FILE] [--keep]
#   --midnight auto     run the midnight-node checks only if the Docker host has at least
#                       MIN_FREE_GB free (default 4); otherwise report them as SKIPPED (default)
#   --midnight require  not enough disk is a setup error, never a skip (CI uses this)
#   --midnight skip     do not run them; reported as SKIPPED
#   -o FILE             also write the report to FILE
#   --keep              leave the stack running for inspection (prints the cleanup command)
#
# Exit codes: 0 PASS (every check ran and passed)  1 FAIL (a check failed)
#             2 ERROR (setup problem)              4 INCOMPLETE (nothing failed, but checks were skipped)
#
# Checks
#   P1-P11  fresh Postgres from the module: init script, TLS settings, pg_hba, read-only role,
#           secret readability, TLS login as `midnight` with verify-full + pgpass, refusals
#   I0-I7   index pre-creation (the phase-2 one-shot container): refuses without the db-sync schema,
#           builds the 11 indexes with the exact definitions, is safe to rerun, rebuilds an INVALID
#           leftover, fails the apply on a conflicting definition; `midnight` stays read-only
#   O1-O3   secret-ownership rules (see infra/README "Secrets"); unreadable / empty role password
#   R1-R3   restart after a FAILED first init (role password missing / empty): Postgres comes back
#           up without the role; the module's healthcheck must keep it unhealthy (control: valid)
#   M1-M11  midnight-node: volume ownership fix, runs as uid 10001, RPC answers, connects to
#           Postgres as `midnight` over TLS, writes chain data as uid 10001, attempts no CREATE
#           INDEX, runs no other DDL the read-only role cannot execute, verifies the DB certificate;
#           M9-M11 run a copy of the node container: control login, untrusted CA and host-name
#           mismatch must both be rejected by the node itself
set -uo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="mn-smoke"
PG_IMAGE="postgres:17.12-bookworm@sha256:40865bc877a289da75963d97d72b59633f639fc5af7a4e856bfa3714cae5b536"
MN_IMAGE="midnightntwrk/midnight-node:2.1.101@sha256:0c1ad548d523c1109aa1f16daab1bf72dcb78c7e17b8a8c6d97424ad0eba7b8a"
MIN_FREE_GB="${MIN_FREE_GB:-4}"     # midnight image (~0.6 GB unpacked) + headroom for anything else on the host
MIDNIGHT_WAIT="${MIDNIGHT_WAIT:-180}"

midnight_mode=auto out="" keep=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --midnight) midnight_mode="${2:-}"; shift 2 ;;
    -o) out="${2:-}"; shift 2 ;;
    --keep) keep=1; shift ;;
    *) echo "usage: $0 [--midnight auto|require|skip] [-o FILE] [--keep]" >&2; exit 2 ;;
  esac
done
[[ "$midnight_mode" =~ ^(auto|require|skip)$ ]] || { echo "error: --midnight must be auto, require or skip" >&2; exit 2; }
for t in docker terraform openssl jq; do command -v "$t" >/dev/null || { echo "error: $t is required" >&2; exit 2; }; done
if [[ -n "$out" ]]; then : > "$out" || { echo "error: cannot write $out" >&2; exit 2; }; fi

say() { echo "$*"; [[ -n "$out" ]] && echo "$*" >> "$out"; return 0; }

# ---- refuse to clobber -----------------------------------------------------------------------
existing="$(docker ps -aq --filter "name=^${PREFIX}-"; docker volume ls -q --filter "name=^${PREFIX}-"; docker network ls -q --filter "name=^${PREFIX}-")"
if [[ -n "$existing" ]]; then
  say "ERROR: ${PREFIX}-* resources already exist; remove them first (or finish a --keep run's cleanup)" >&2; exit 2
fi

run_midnight=0
WORK="$(mktemp -d)"
SECRETS="$WORK/secrets"
# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  if (( keep )); then
    echo "kept: stack in $WORK/tf. Clean up with: (cd $WORK/tf && terraform destroy -auto-approve); docker rm -fv \$(docker ps -aq --filter name=^${PREFIX}-); docker run --rm -v $WORK:/w ${PG_IMAGE} rm -rf /w/secrets /w/neg; rm -rf $WORK"
    return
  fi
  local destroy_log="" left
  if [[ -f "$WORK/tf/terraform.tfstate" ]]; then
    destroy_log="$(cd "$WORK/tf" && terraform destroy -auto-approve -input=false -no-color -var "with_midnight=$( ((run_midnight)) && echo true || echo false)" 2>&1)" \
      || echo "cleanup: terraform destroy failed, removing ${PREFIX}-* directly: $(grep -m1 -E 'Error' <<<"$destroy_log")" >&2
  fi
  # Fallback, strictly limited to the mn-smoke- prefix: containers first, then volumes, networks.
  # shellcheck disable=SC2046  # one argument per id
  { docker rm -fv $(docker ps -aq --filter "name=^${PREFIX}-"); docker volume rm $(docker volume ls -q --filter "name=^${PREFIX}-"); \
    docker network rm $(docker network ls -q --filter "name=^${PREFIX}-"); } >/dev/null 2>&1
  # Secret files are owned by uid 999/10001: remove them as root, inside a throwaway container.
  docker run --rm --network none -v "$WORK:/w" "$PG_IMAGE" rm -rf /w/secrets /w/neg >/dev/null 2>&1
  rm -rf "$WORK"
  left="$(docker ps -aq --filter "name=^${PREFIX}-"; docker volume ls -q --filter "name=^${PREFIX}-"; docker network ls -q --filter "name=^${PREFIX}-")"
  if [[ -n "$left" ]]; then echo "cleanup: LEFTOVER ${PREFIX}-* resources, remove manually: $(tr '\n' ' ' <<<"$left")" >&2
  else echo "cleanup: all ${PREFIX}-* resources and scratch secrets removed" >&2; fi
}
trap cleanup EXIT

# ---- result bookkeeping ----------------------------------------------------------------------
declare -a R_ID R_STATUS R_DESC
record() {  # $1=PASS|FAIL|SKIP $2=id $3=description $4=evidence (optional)
  R_STATUS+=("$1"); R_ID+=("$2"); R_DESC+=("$3")
  say "$(printf '%-4s  %-3s %s' "$1" "$2" "$3")"
  [[ -n "${4:-}" ]] && while IFS= read -r l; do say "            $l"; done <<<"$4"
  return 0
}
check() {  # $1=id $2=description $3=expected ERE $4=actual
  if grep -qE -- "$3" <<<"$4"; then record PASS "$1" "$2" "$4"; else record FAIL "$1" "$2" "$4"; fi
}

say "# infra smoke test  run_utc=$(date -u +%FT%TZ)  host=$(uname -n)  midnight=$midnight_mode"
say "# modules: $INFRA/modules/{network,postgres,midnight-node}  docker provider 4.7.0"

# ---- decide whether the midnight-node checks can run ------------------------------------------
docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
free_kb="$(df -Pk "$docker_root" 2>/dev/null | awk 'NR==2{print $4}')"; free_kb="${free_kb:-0}"
free_gb_x10=$(( free_kb * 10 / 1024 / 1024 ))
skip_reason=""
case "$midnight_mode" in
  skip) skip_reason="disabled with --midnight skip" ;;
  auto|require)
    if (( free_kb < MIN_FREE_GB * 1024 * 1024 )); then
      skip_reason="only $((free_gb_x10 / 10)).$((free_gb_x10 % 10)) GB free under $docker_root (need >= ${MIN_FREE_GB} GB to pull midnight-node and leave headroom)"
      if [[ "$midnight_mode" == require ]]; then
        say "ERROR: --midnight require, but $skip_reason"; exit 2
      fi
    fi ;;
esac
[[ -z "$skip_reason" ]] && run_midnight=1

# ---- scratch secrets and a throwaway CA (never printed) ---------------------------------------
mkdir -p "$SECRETS/postgres/tls" "$SECRETS/midnight" "$WORK/ca" "$WORK/neg" "$WORK/tf"
(
  umask 077
  printf cexplorer > "$SECRETS/postgres/postgres_db"
  printf postgres > "$SECRETS/postgres/postgres_user"
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$SECRETS/postgres/postgres_password"
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$SECRETS/postgres/midnight_db_password"
  printf 'postgres:5432:cexplorer:midnight:%s\n' "$(cat "$SECRETS/postgres/midnight_db_password")" > "$SECRETS/midnight/pgpass"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=${PREFIX}-ca" -keyout "$WORK/ca/ca.key" -out "$WORK/ca/ca.crt" 2>/dev/null
  openssl req -newkey rsa:2048 -nodes -subj "/CN=postgres" -keyout "$SECRETS/postgres/tls/server.key" -out "$WORK/ca/server.csr" 2>/dev/null
  printf 'subjectAltName=DNS:postgres\n' > "$WORK/ca/san.ext"
  openssl x509 -req -in "$WORK/ca/server.csr" -CA "$WORK/ca/ca.crt" -CAkey "$WORK/ca/ca.key" -CAcreateserial -days 1 \
    -extfile "$WORK/ca/san.ext" -out "$SECRETS/postgres/tls/server.crt" 2>/dev/null
  cp "$WORK/ca/ca.crt" "$SECRETS/midnight/postgres-ca.crt"
) || { say "ERROR: generating scratch secrets failed"; exit 2; }
# Negative-test material for M10/M11: a CA nobody trusts, and a pgpass entry for ANY host, so that
# if the node skipped certificate/host-name checks the login would actually succeed (and be seen).
mkdir -p "$SECRETS/midnight-neg"
(
  umask 077
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=postgres" -addext "subjectAltName=DNS:postgres" \
    -keyout "$WORK/ca/rogue.key" -out "$SECRETS/midnight-neg/rogue-ca.crt" 2>/dev/null
  printf '*:5432:cexplorer:midnight:%s\n' "$(cat "$SECRETS/postgres/midnight_db_password")" > "$SECRETS/midnight-neg/pgpass-any"
) || { say "ERROR: generating negative-test material failed"; exit 2; }
# Ownership per the host contract (infra/README "Secrets"), set as root in a throwaway container.
docker run --rm --network none -v "$SECRETS:/s" "$PG_IMAGE" sh -c '
  chown -R 999:999 /s/postgres && chmod 755 /s/postgres /s/postgres/tls && chmod 600 /s/postgres/postgres_* /s/postgres/midnight_db_password /s/postgres/tls/server.key && chmod 644 /s/postgres/tls/server.crt &&
  chown -R 10001:10001 /s/midnight /s/midnight-neg && chmod 755 /s/midnight /s/midnight-neg && chmod 600 /s/midnight/pgpass /s/midnight-neg/pgpass-any && chmod 644 /s/midnight/postgres-ca.crt /s/midnight-neg/rogue-ca.crt' \
  || { say "ERROR: could not set secret ownership"; exit 2; }

# ---- smoke root module: the real modules, separate state --------------------------------------
cat > "$WORK/tf/main.tf" <<EOF
terraform {
  required_version = "~> 1.17.0"
  required_providers {
    docker = { source = "kreuzwerker/docker", version = "4.7.0" }
  }
  backend "local" {}
}
provider "docker" {}
variable "with_midnight" {
  type    = bool
  default = false
}
variable "with_indexes" {
  type    = bool
  default = false
}
locals {
  common = {
    prefix   = "$PREFIX"
    labels   = { "managed-by" = "terraform", "mn.stack" = "$PREFIX", "mn.purpose" = "smoke-test" }
    log_opts = { "max-size" = "10m", "max-file" = "1" }
  }
}
module "network" {
  source = "$INFRA/modules/network"
  common = local.common
}
module "postgres" {
  source           = "$INFRA/modules/postgres"
  common           = local.common
  image            = "$PG_IMAGE"
  storage_gb       = 1
  internal_network = module.network.internal
  secrets_dir      = "$SECRETS/postgres"
  tuning           = { shared_buffers = "128MB", log_connections = "on" } # log_connections: evidence for M4
}
module "midnight_db_indexes" {
  source           = "$INFRA/modules/midnight-db-indexes"
  count            = var.with_indexes ? 1 : 0 # phase-2 one-shot, exercised by the I checks
  common           = local.common
  image            = "$PG_IMAGE"
  internal_network = module.network.internal
  postgres_host    = module.postgres.host
  secrets_dir      = "$SECRETS/postgres"
}
module "midnight_node" {
  source                     = "$INFRA/modules/midnight-node"
  count                      = var.with_midnight ? 1 : 0
  common                     = local.common
  image                      = "$MN_IMAGE"
  storage_gb                 = 1
  start                      = false # phase-1 config; the test starts it with docker start (no 300 s Terraform wait)
  cfg_preset                 = "preprod"
  chain_spec                 = "/res/preprod/chain-spec-raw.json"
  cardano_security_parameter = 2160
  node_name                  = "$PREFIX"
  extra_args                 = ["--pool-limit", "35", "--no-private-ip"]
  p2p_network                = module.network.p2p
  internal_network           = module.network.internal
  p2p_host_port              = 39333
  rpc_host_port              = 39944
  postgres_host              = module.postgres.host
  postgres_db                = module.postgres.dbsync_database
  postgres_role              = module.postgres.midnight_role
  secrets_dir                = "$SECRETS/midnight"
}
EOF
plugin_args=(); [[ -d "$INFRA/.terraform/providers" ]] && plugin_args=(-plugin-dir="$INFRA/.terraform/providers")
(cd "$WORK/tf" && terraform init -input=false -no-color "${plugin_args[@]}" >/dev/null 2>&1) || { say "ERROR: terraform init failed"; exit 2; }
say "# applying ${PREFIX} stack (postgres$( ((run_midnight)) && echo ' + midnight-node, created stopped'))"
tfa() {  # $1 = with_indexes (true|false), rest = extra terraform args
  (cd "$WORK/tf" && terraform apply -auto-approve -input=false -no-color \
     -var "with_midnight=$( ((run_midnight)) && echo true || echo false)" -var "with_indexes=$1" "${@:2}" 2>&1)
}
if ! apply_log="$(tfa false)"; then
  record FAIL P0 "terraform apply of the smoke stack" "$(tail -15 <<<"$apply_log")"
  exit 1
fi
say "# $(grep -E '^Apply complete' <<<"$apply_log")"

PG="${PREFIX}-postgres"; NET="${PREFIX}-internal"; PGIMG="$PG_IMAGE"
asroot() { docker exec "$PG" psql -X -At -U postgres -d cexplorer -c "$1" 2>&1; }
client() {  # as uid 10001 with midnight-node's secret mounts
  docker run --rm --network "$NET" --user 10001:10001 -e PGPASSFILE=/run/secrets/midnight/pgpass -e PGCONNECT_TIMEOUT=5 \
    -v "$SECRETS/midnight/pgpass:/run/secrets/midnight/pgpass:ro" -v "$SECRETS/midnight/postgres-ca.crt:/run/secrets/midnight/postgres-ca.crt:ro" \
    "$PGIMG" psql -X -At "$1" -c "$2" 2>&1
}
TLS="host=postgres port=5432 dbname=cexplorer user=midnight sslmode=verify-full sslrootcert=/run/secrets/midnight/postgres-ca.crt"

# ---- P: fresh Postgres from the module --------------------------------------------------------
say ""; say "## Postgres (fresh volume, module infra/modules/postgres)"
check P1 "fresh volume initialised and ran 10-midnight-role.sh" 'running /docker-entrypoint-initdb.d/10-midnight-role.sh' \
  "$(docker logs "$PG" 2>&1 | grep -E 'initdb.d/10-midnight-role.sh|Permission denied|database system is ready' | head -3)"
check P2 "ssl=on, min TLSv1.2, scram-sha-256" '^on TLSv1.2 scram-sha-256 $' \
  "$(asroot 'SHOW ssl; SHOW ssl_min_protocol_version; SHOW password_encryption;' | tr '\n' ' ')"
check P3 "pg_hba: midnight = hostssl scram, plain host reject" 'hostssl\|\{midnight\}\|scram-sha-256;.*host\|\{midnight\}\|reject' \
  "$(asroot 'SELECT line_number, type, user_name, auth_method FROM pg_hba_file_rules ORDER BY line_number;' | tr '\n' ';')"
check P4 "role midnight: login with a password, no admin rights, read-only default" '^f\|f\|f\|t\|f\|default_transaction_read_only=on$' \
  "$(asroot "SELECT r.rolsuper, r.rolcreatedb, r.rolcreaterole, r.rolcanlogin, (SELECT a.rolpassword IS NULL FROM pg_authid a WHERE a.rolname = r.rolname), array_to_string(r.rolconfig, ',') FROM pg_roles r WHERE r.rolname='midnight';")"
check P5 "files Postgres opens itself (TLS key, role password) readable as uid 999" '^ +2 ok $' \
  "$(docker exec -u 999 "$PG" sh -c 'for f in /run/secrets/tls/server.key /run/secrets/midnight_db_password; do test -r $f && echo ok || echo "NOT-READABLE $f"; done' | sort | uniq -c | tr '\n' ' ')"
check P6 "pgpass is 0600 and owned by uid 10001 as the node sees it" '^600 10001$' \
  "$(docker run --rm --network none --user 10001:10001 -v "$SECRETS/midnight/pgpass:/p:ro" "$PGIMG" stat -c '%a %u' /p)"
check P7 "TLS login as midnight (verify-full, password from pgpass)" '^midnight\|t\|TLSv1\.[23]$' \
  "$(client "$TLS" 'SELECT current_user, s.ssl, s.version FROM pg_stat_ssl s WHERE s.pid = pg_backend_pid();')"
check P8 "non-TLS login as midnight rejected" 'rejects connection.*no encryption' \
  "$(client 'host=postgres dbname=cexplorer user=midnight sslmode=disable' 'SELECT 1')"
pg_ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$PG")"
check P9 "verify-full rejects a host name not in the certificate SAN" 'does not match host name' \
  "$(client "host=$pg_ip dbname=cexplorer user=midnight sslmode=verify-full sslrootcert=/run/secrets/midnight/postgres-ca.crt" 'SELECT 1')"
asroot "CREATE TABLE IF NOT EXISTS block (id bigint, block_no bigint); TRUNCATE block; INSERT INTO block VALUES (1, 42);" >/dev/null
check P10 "SELECT on a table db-sync creates later (default privileges)" '^42$' "$(client "$TLS" 'SELECT block_no FROM block;')"
check P11 "writes refused: INSERT (read-only default), INSERT in READ WRITE txn (no grant), CREATE TABLE" \
  'read-only transaction.*permission denied for table block.*(read-only transaction|permission denied)' \
  "$( { client "$TLS" 'INSERT INTO block VALUES (2, 43);'; client "$TLS" 'BEGIN READ WRITE; INSERT INTO block VALUES (3, 44); COMMIT;'; client "$TLS" 'CREATE TABLE evil (x int);'; } | grep -E 'ERROR' | tr '\n' ' ')"
asroot "DROP TABLE block;" >/dev/null

# ---- I: index pre-creation (phase 2) ----------------------------------------------------------
say ""; say "## midnight-node index pre-creation (modules/midnight-db-indexes one-shot, files/midnight-indexes.sh)"
IDX="${PREFIX}-midnight-db-indexes"
IDX_REPLACE="-replace=module.midnight_db_indexes[0].docker_container.this"
idx_state() {
  asroot "SELECT string_agg(c.relname || ' valid=' || i.indisvalid || ' ' || pg_get_indexdef(i.indexrelid), E'\n' ORDER BY c.relname)
            FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
           WHERE c.relname IN ('idx_block_block_no','idx_ma_tx_out_id_ident','idx_ma_tx_out_ident','idx_multi_asset_policy_name','idx_multi_asset_policy_name_hex','idx_tx_block_id','idx_tx_in_tx_in_id','idx_tx_in_tx_out_id_tx_out_index','idx_tx_out_address','idx_tx_out_data_hash','idx_tx_out_tx_id');"
}
IDX_WANT="idx_block_block_no valid=true CREATE INDEX idx_block_block_no ON public.block USING btree (block_no)
idx_ma_tx_out_id_ident valid=true CREATE INDEX idx_ma_tx_out_id_ident ON public.ma_tx_out USING btree (tx_out_id, ident)
idx_ma_tx_out_ident valid=true CREATE INDEX idx_ma_tx_out_ident ON public.ma_tx_out USING btree (ident)
idx_multi_asset_policy_name valid=true CREATE INDEX idx_multi_asset_policy_name ON public.multi_asset USING btree (policy, name)
idx_multi_asset_policy_name_hex valid=true CREATE INDEX idx_multi_asset_policy_name_hex ON public.multi_asset USING btree (encode((policy)::bytea, 'hex'::text), encode((name)::bytea, 'hex'::text))
idx_tx_block_id valid=true CREATE INDEX idx_tx_block_id ON public.tx USING btree (block_id)
idx_tx_in_tx_in_id valid=true CREATE INDEX idx_tx_in_tx_in_id ON public.tx_in USING btree (tx_in_id)
idx_tx_in_tx_out_id_tx_out_index valid=true CREATE INDEX idx_tx_in_tx_out_id_tx_out_index ON public.tx_in USING btree (tx_out_id, tx_out_index)
idx_tx_out_address valid=true CREATE INDEX idx_tx_out_address ON public.tx_out USING hash (address)
idx_tx_out_data_hash valid=true CREATE INDEX idx_tx_out_data_hash ON public.tx_out USING btree (data_hash)
idx_tx_out_tx_id valid=true CREATE INDEX idx_tx_out_tx_id ON public.tx_out USING btree (tx_id)"

# I0: before db-sync has created its schema the script must refuse (same env/mounts as the one-shot).
i0="$(docker run --rm --network "$NET" -e PGHOST=postgres -e PGPORT=5432 \
  -e POSTGRES_DB_FILE=/run/secrets/postgres_db -e POSTGRES_USER_FILE=/run/secrets/postgres_user -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -v "$SECRETS/postgres/postgres_db:/run/secrets/postgres_db:ro" -v "$SECRETS/postgres/postgres_user:/run/secrets/postgres_user:ro" \
  -v "$SECRETS/postgres/postgres_password:/run/secrets/postgres_password:ro" \
  -v "$INFRA/modules/midnight-db-indexes/files/midnight-indexes.sh:/usr/local/bin/midnight-indexes.sh:ro" \
  --entrypoint /bin/bash "$PG_IMAGE" /usr/local/bin/midnight-indexes.sh 2>&1; echo "exit=$?")"
check I0 "without the db-sync schema the script refuses clearly" 'db-sync tables missing: block, tx, tx_out, tx_in, multi_asset, ma_tx_out.*exit=1' "$(tr '\n' ' ' <<<"$i0")"

# Minimal db-sync schema with the REAL column types of db-sync 13.7.1.0 (read from the live PreProd
# database on 2026-11-19): policy/name are bytea domains, which changes pg_get_indexdef's output.
asroot "CREATE DOMAIN hash28type AS bytea CHECK (octet_length(VALUE) = 28);
        CREATE DOMAIN hash32type AS bytea CHECK (octet_length(VALUE) = 32);
        CREATE DOMAIN asset32type AS bytea CHECK (octet_length(VALUE) <= 32);
        CREATE DOMAIN word31type AS integer CHECK (VALUE >= 0);
        CREATE DOMAIN txindex AS smallint CHECK (VALUE >= 0);
        CREATE TABLE block (id bigserial PRIMARY KEY, block_no word31type);
        CREATE TABLE tx (id bigserial PRIMARY KEY, block_id bigint NOT NULL);
        CREATE TABLE tx_out (id bigserial PRIMARY KEY, tx_id bigint NOT NULL, index txindex NOT NULL, address character varying NOT NULL, data_hash hash32type);
        CREATE TABLE tx_in (id bigserial PRIMARY KEY, tx_in_id bigint NOT NULL, tx_out_id bigint NOT NULL, tx_out_index txindex NOT NULL);
        CREATE TABLE multi_asset (id bigserial PRIMARY KEY, policy hash28type NOT NULL, name asset32type NOT NULL);
        CREATE TABLE ma_tx_out (id bigserial PRIMARY KEY, tx_out_id bigint NOT NULL, ident bigint NOT NULL);
        CREATE TABLE datum (id bigserial PRIMARY KEY, hash hash32type NOT NULL);" >/dev/null

# I1/I2: phase-2 apply runs the one-shot; all three indexes valid with the exact definitions.
if i1_log="$(tfa true)"; then i1_rc=0; else i1_rc=1; fi
check I1 "phase-2 apply runs the one-shot: exit 0, 11 indexes created" '^apply=0 container_exit=0 created=11$' \
  "apply=$i1_rc container_exit=$(docker inspect -f '{{.State.ExitCode}}' "$IDX" 2>&1) created=$(docker logs "$IDX" 2>&1 | grep -c ': created, valid, definition matches')$( ((i1_rc)) && printf '\n%s' "$(tail -4 <<<"$i1_log")")"
i2="$(idx_state)"
if [[ "$i2" == "$IDX_WANT" ]]; then record PASS I2 "11 indexes valid, definitions identical to midnight-node 2.1.101" "$i2"
else record FAIL I2 "11 indexes valid, definitions identical to midnight-node 2.1.101" "got:
$i2
want:
$IDX_WANT"; fi

# I3: rerun (replace the one-shot) is a no-op.
if tfa true "$IDX_REPLACE" >/dev/null; then i3_rc=0; else i3_rc=1; fi
check I3 "rerun is safe: nothing rebuilt, definitions unchanged" '^apply=0 unchanged=11 same_state=yes$' \
  "apply=$i3_rc unchanged=$(docker logs "$IDX" 2>&1 | grep -c 'present and valid, definition matches: nothing to do') same_state=$([[ "$(idx_state)" == "$IDX_WANT" ]] && echo yes || echo no)"

# I4: an INVALID leftover (interrupted CONCURRENTLY build, simulated) is dropped and rebuilt.
asroot "UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'public.idx_tx_out_address'::regclass;" >/dev/null
if tfa true "$IDX_REPLACE" >/dev/null; then i4_rc=0; else i4_rc=1; fi
check I4 "INVALID leftover is dropped and rebuilt" '^apply=0 rebuilt=1 same_state=yes$' \
  "apply=$i4_rc rebuilt=$(docker logs "$IDX" 2>&1 | grep -c 'idx_tx_out_address: INVALID leftover') same_state=$([[ "$(idx_state)" == "$IDX_WANT" ]] && echo yes || echo no)"

# I5: same name, different definition -> the script fails and the postcondition fails the apply.
asroot "DROP INDEX idx_tx_out_address; CREATE INDEX idx_tx_out_address ON tx_out USING btree (address);" >/dev/null
if i5_log="$(tfa true "$IDX_REPLACE")"; then i5_rc=0; else i5_rc=1; fi
i5="apply=$i5_rc postcondition=$(grep -c 'midnight-indexes.sh failed' <<<"$i5_log") script=$(docker logs "$IDX" 2>&1 | grep -c 'idx_tx_out_address exists with a different definition')"
asroot "DROP INDEX idx_tx_out_address;" >/dev/null            # restore for the M checks
if tfa true "$IDX_REPLACE" >/dev/null && [[ "$(idx_state)" == "$IDX_WANT" ]]; then i5="$i5 restored=yes"; else i5="$i5 restored=no"; fi
check I5 "conflicting definition fails the apply loudly (script + postcondition), then recovers" \
  '^apply=1 postcondition=[1-9][0-9]* script=1 restored=yes$' "$i5"
say "            $(docker logs "$IDX" 2>&1 | tail -1)"

# I7: the RUNBOOK 8.1 invocation for the compose stack (socket mode, script on stdin) is a no-op now.
i7="$(docker exec -i -e POSTGRES_DB_FILE=/run/secrets/postgres_db -e POSTGRES_USER_FILE=/run/secrets/postgres_user \
  "$PG" bash < "$INFRA/modules/midnight-db-indexes/files/midnight-indexes.sh" 2>&1; echo "exit=$?")"
check I7 "RUNBOOK socket-mode invocation (docker exec ... bash < script): 11 x nothing to do" '^unchanged=11 exit=0$' \
  "unchanged=$(grep -c 'nothing to do' <<<"$i7") $(tail -1 <<<"$i7")"

# I6: the runtime role is still read-only.
check I6 "role midnight still read-only: no CREATE on schema, no INSERT on tx_out, write refused" \
  '^f\|f ERROR: .*(read-only transaction|permission denied)' \
  "$(asroot "SELECT has_schema_privilege('midnight','public','CREATE'), has_table_privilege('midnight','public.tx_out','INSERT');") $(client "$TLS" "INSERT INTO tx_out (address) VALUES ('x');" | grep ERROR)"

# ---- O: secret-ownership rules (fresh volumes, plain docker run, same image + init script) ----
say ""; say "## Secret-ownership rules"
neg_pg() {  # $1=name; files in $WORK/neg; prints final status and the relevant log lines
  docker run -d --name "$1" --network none \
    -e POSTGRES_DB_FILE=/run/secrets/postgres_db -e POSTGRES_USER_FILE=/run/secrets/postgres_user \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password -e MIDNIGHT_DB_PASSWORD_FILE=/run/secrets/midnight_db_password \
    -v "$WORK/neg/postgres_db:/run/secrets/postgres_db:ro" -v "$WORK/neg/postgres_user:/run/secrets/postgres_user:ro" \
    -v "$WORK/neg/postgres_password:/run/secrets/postgres_password:ro" -v "$WORK/neg/midnight_db_password:/run/secrets/midnight_db_password:ro" \
    -v "$INFRA/modules/postgres/files/10-midnight-role.sh:/docker-entrypoint-initdb.d/10-midnight-role.sh:ro" \
    -v /var/lib/postgresql/data "$PG_IMAGE" >/dev/null || { echo "status=could-not-start"; return; }
  for _ in $(seq 1 45); do
    [[ "$(docker inspect -f '{{.State.Status}}' "$1")" == exited ]] && break
    docker logs "$1" 2>&1 | grep -q 'init process complete' && break
    sleep 1
  done
  echo "status=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$1")"
  docker logs "$1" 2>&1 | grep -E 'superuser password|Permission denied|10-midnight-role|init process complete|cannot read' | head -5
  if [[ "$(docker inspect -f '{{.State.Status}}' "$1")" == running ]]; then
    echo "midnight role has no password: $(docker exec "$1" psql -X -At -U postgres -d cexplorer -c "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname='midnight';" 2>&1)"
  fi
  docker rm -fv "$1" >/dev/null 2>&1
}
( umask 077
  printf cexplorer > "$WORK/neg/postgres_db"; printf postgres > "$WORK/neg/postgres_user"
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$WORK/neg/postgres_password"
  od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "$WORK/neg/midnight_db_password" )
# O1: the three *_FILE secrets owned by the operator (0600): the entrypoint reads them as root.
docker run --rm --network none -v "$WORK/neg:/n" "$PG_IMAGE" chown 999:999 /n/midnight_db_password
check O1 "operator-owned 0600 postgres_db/user/password: fresh init succeeds (read as root)" 'status=running.*init process complete.*no password: f' \
  "$(neg_pg "${PREFIX}-o1" | tr '\n' ' ')"
# O2: midnight_db_password NOT readable by uid 999: the init script reads it as postgres, so init
# must fail loudly rather than create a role without a password.
docker run --rm --network none -v "$WORK/neg:/n" "$PG_IMAGE" chown "$(id -u):$(id -g)" /n/midnight_db_password
check O2 "unreadable midnight_db_password: init aborts with a clear error (no password-less role)" \
  'status=exited exit=[1-9].*10-midnight-role.sh: ERROR: .*midnight_db_password is not readable by postgres \(uid 999\)' \
  "$(neg_pg "${PREFIX}-o2" | tr '\n' ' ')"
# O3: empty (whitespace-only) midnight_db_password, readable by uid 999: also a clear abort.
docker run --rm --network none -v "$WORK/neg:/n" "$PG_IMAGE" sh -c 'printf "  \n" > /n/midnight_db_password && chown 999:999 /n/midnight_db_password'
check O3 "empty midnight_db_password: init aborts with a clear error" \
  'status=exited exit=[1-9].*10-midnight-role.sh: ERROR: .*midnight_db_password is empty' \
  "$(neg_pg "${PREFIX}-o3" | tr '\n' ' ')"

# ---- R: restart after a failed first initialisation -----------------------------------------
say ""; say "## Restart after a failed first init (module healthcheck, files/healthcheck.sh)"
restart_pg() {  # $1=name $2=missing|empty|valid -> evidence line
  local name="$1" mode="$2" pwmount=() st
  docker run --rm --network none -v "$WORK/neg:/n" "$PG_IMAGE" sh -c '
    printf "%s" "$(od -An -tx1 -N16 /dev/urandom | tr -d " \n")" > /n/midnight_db_password && chown 999:999 /n/midnight_db_password'
  case "$mode" in
    empty) docker run --rm --network none -v "$WORK/neg:/n" "$PG_IMAGE" sh -c ': > /n/midnight_db_password' ;;
  esac
  [[ "$mode" != missing ]] && pwmount=(-v "$WORK/neg/midnight_db_password:/run/secrets/midnight_db_password:ro")
  docker run -d --name "$name" --network none --restart unless-stopped \
    -e POSTGRES_DB_FILE=/run/secrets/postgres_db -e POSTGRES_USER_FILE=/run/secrets/postgres_user \
    -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password -e MIDNIGHT_DB_PASSWORD_FILE=/run/secrets/midnight_db_password \
    -v "$WORK/neg/postgres_db:/run/secrets/postgres_db:ro" -v "$WORK/neg/postgres_user:/run/secrets/postgres_user:ro" \
    -v "$WORK/neg/postgres_password:/run/secrets/postgres_password:ro" "${pwmount[@]}" \
    -v "$INFRA/modules/postgres/files/10-midnight-role.sh:/docker-entrypoint-initdb.d/10-midnight-role.sh:ro" \
    -v "$INFRA/modules/postgres/files/healthcheck.sh:/usr/local/bin/mn-pg-healthcheck.sh:ro" \
    --health-cmd "/bin/bash /usr/local/bin/mn-pg-healthcheck.sh" --health-interval 3s --health-timeout 5s \
    --health-retries 3 --health-start-period 5s \
    -v /var/lib/postgresql/data "$PG_IMAGE" >/dev/null || { echo "could-not-start"; return; }
  # Failing modes: wait for the restart; then let the healthcheck settle. Control: wait for healthy.
  for _ in $(seq 1 60); do
    st="$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")"
    if [[ "$mode" == valid ]]; then [[ "$st" == "running 0 healthy" ]] && break
    else [[ "$st" =~ ^running\ [1-9][0-9]*\ unhealthy$ ]] && break; fi
    sleep 2
  done
  local logs; logs="$(docker logs "$name" 2>&1)"
  echo "restarts=$(docker inspect -f '{{.RestartCount}}' "$name")" \
       "init_aborted=$(grep -c '10-midnight-role.sh: ERROR' <<<"$logs")" \
       "skipped_init_on_restart=$(grep -c 'Skipping initialization' <<<"$logs")" \
       "pg_isready=$(docker exec "$name" pg_isready -q -U postgres >/dev/null 2>&1 && echo ok || echo fail)" \
       "health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name")"
  echo "health output: $(docker inspect -f '{{json .State.Health}}' "$name" 2>/dev/null | jq -r '(.Log // [])[-1].Output // "none"' | tr -d '\n' | cut -c1-160)"
  docker rm -fv "$name" >/dev/null 2>&1
}
check R1 "role password file MISSING: init aborts; after restart Postgres runs but stays unhealthy" \
  '^restarts=[1-9][0-9]* init_aborted=[1-9][0-9]* skipped_init_on_restart=[1-9][0-9]* pg_isready=ok health=unhealthy health output: UNHEALTHY: role .midnight. does not exist' \
  "$(restart_pg "${PREFIX}-r1" missing | tr '\n' ' ' | sed 's/ $//; s/ health output:/ health output:/')"
check R2 "role password file EMPTY: init aborts; after restart Postgres runs but stays unhealthy" \
  '^restarts=[1-9][0-9]* init_aborted=[1-9][0-9]* skipped_init_on_restart=[1-9][0-9]* pg_isready=ok health=unhealthy health output: UNHEALTHY: role .midnight. does not exist' \
  "$(restart_pg "${PREFIX}-r2" empty | tr '\n' ' ' | sed 's/ $//')"
check R3 "control: valid role password: initialises once and reports healthy" \
  '^restarts=0 init_aborted=0 skipped_init_on_restart=0 pg_isready=ok health=healthy health output: ok: ' \
  "$(restart_pg "${PREFIX}-r3" valid | tr '\n' ' ' | sed 's/ $//')"

# ---- M: midnight-node as uid 10001 ------------------------------------------------------------
say ""; say "## midnight-node (module infra/modules/midnight-node, uid 10001)"
MN="${PREFIX}-midnight-node"; MNVOL="${PREFIX}-midnight-node-data"
if (( ! run_midnight )); then
  for c in "M1|volume-init fixed base-path ownership (10001, 0700)" "M2|node process runs as uid 10001" \
           "M3|RPC answers system_health" "M4|node logs in to Postgres as midnight over TLS (server log)" \
           "M5|node writes chain data owned by uid 10001" \
           "M6|node attempts no CREATE INDEX (all pre-created indexes found)" \
           "M7|node runs no DDL the read-only role cannot execute" \
           "M8|node verifies the Postgres certificate (SSL mode VerifyFull)" \
           "M9|control: copy of the node container with the correct CA and host logs in" \
           "M10|node rejects a Postgres certificate from an untrusted CA" \
           "M11|node rejects a host-name mismatch (connects by IP; certificate is for 'postgres')"; do
    record SKIP "${c%%|*}" "${c#*|}" "NOT VERIFIED: $skip_reason"
  done
else
  check M1 "volume-init fixed base-path ownership (10001, 0700)" '^exit=0 700 10001$' \
    "exit=$(docker inspect -f '{{.State.ExitCode}}' "${MN}-volume-init") $(docker run --rm --network none -v "$MNVOL:/v:ro" "$PG_IMAGE" stat -c '%a %u' /v)"
  # Only Postgres log lines written after this point count for M4 (the P-check clients also
  # log in as midnight over TLS, earlier).
  pg_log_mark=$(docker logs "$PG" 2>&1 | wc -l)
  docker start "$MN" >/dev/null 2>&1
  rpc_ok="" uids="" deadline=$(( $(date +%s) + MIDNIGHT_WAIT ))
  while (( $(date +%s) < deadline )); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$MN")" == true ]]; then
      # sample while it runs: a node that exits early still shows which uid it ran as
      [[ -z "$uids" ]] && uids="$(docker top "$MN" -o pid,uid 2>/dev/null | awk 'NR>1{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')"
      [[ -z "$rpc_ok" ]] && rpc_ok="$(docker exec "$MN" curl -fsS -m 5 -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"system_health","params":[]}' http://127.0.0.1:9944 2>/dev/null | jq -c '.result' 2>/dev/null)"
      [[ -n "$rpc_ok" && -n "$uids" ]] && break
    elif [[ "$(docker inspect -f '{{.RestartCount}}' "$MN")" -ge 2 ]]; then
      break   # crash-looping: no point waiting out the full window
    fi
    sleep 2
  done
  state="$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$MN")"
  if [[ -n "$uids" ]]; then
    check M2 "node process runs as uid 10001" '^observed uids: 10001$' "observed uids: $uids"
  else
    # Exited before it could be sampled: use what the process left behind. volume-init only
    # chowned the directory, so every file under it was created by the node process itself.
    ev="$(docker run --rm --network none -v "$MNVOL:/v:ro" "$PG_IMAGE" sh -c 'echo "node-created files=$(find /v -mindepth 1 | wc -l) owned_by_other_than_10001=$(find /v -mindepth 1 ! -user 10001 | wc -l)"')"
    check M2 "node process runs as uid 10001 (not sampled while running; evidence: files it created)" \
      "^config_user=10001:10001 node-created files=[1-9][0-9]* owned_by_other_than_10001=0\$" \
      "config_user=$(docker inspect -f '{{.Config.User}}' "$MN") $ev"
  fi
  check M3 "RPC answers system_health" '"peers"' "${rpc_ok:-no answer within ${MIDNIGHT_WAIT}s; container $state}"
  check M4 "node logs in to Postgres as midnight over TLS (server log)" 'connection authorized: user=midnight database=cexplorer.*SSL enabled \(protocol=TLSv1\.[23]' \
    "$(docker logs "$PG" 2>&1 | tail -n +$((pg_log_mark + 1)) | grep -E 'connection authorized: user=midnight' | tail -1 | sed 's/^.*LOG: *//')"
  check M5 "node writes chain data owned by uid 10001" '^files=[1-9][0-9]* not_10001=0$' \
    "$(docker run --rm --network none -v "$MNVOL:/v:ro" "$PG_IMAGE" sh -c 'echo "files=$(find /v -mindepth 1 | wc -l) not_10001=$(find /v ! -user 10001 | wc -l)"')"
  mlog="$(docker logs "$MN" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
  check M6 "node attempts no CREATE INDEX (all pre-created indexes found)" '^found_present=[1-9][0-9]* create_attempts=0 create_index_errors=0$' \
    "found_present=$(grep -oE "Index '?idx_[a-z_]+'? already exists" <<<"$mlog" | sort -u | wc -l) create_attempts=$(grep -cE "Creating index|Executing 'CREATE INDEX|Creating idx_" <<<"$mlog") create_index_errors=$(grep -c 'cannot execute CREATE INDEX' <<<"$mlog")"
  check M7 "node runs no DDL the read-only role cannot execute" '^ddl_errors=0$' \
    "ddl_errors=$(grep -cE 'cannot execute (ALTER|CREATE|DROP|TRUNCATE)[A-Z ]* in a read-only transaction' <<<"$mlog")$(grep -m1 -oE 'error: .*cannot execute [A-Z ]+ in a read-only transaction' <<<"$mlog" | sed 's/^/ first: /')"
  # The node ignores sslmode/sslrootcert in the URL and uses its own ssl_root_cert setting
  # (env SSL_ROOT_CERT, node/src/cfg/midnight_cfg/mod.rs); without it: Require, no cert check.
  check M8 "node verifies the Postgres certificate (SSL mode VerifyFull)" '^Database connection SSL mode: VerifyFull' \
    "$(grep -m1 -oE 'Database connection SSL mode: [A-Za-z]+' <<<"$mlog" || echo 'no SSL mode line in the node log')$(grep -m1 -oE 'No ssl_root_cert configured[^.]*' <<<"$mlog" | sed 's/^/ | /')"
  # M9-M11: copies of the module's node container (image, user, args, env from docker inspect), with
  # only the TLS inputs changed. pgpass-any matches every host, so if the node did not verify the
  # certificate / host name, the login WOULD succeed and show up in the Postgres log.
  node_clone() {  # $1=name $2=SSL_ROOT_CERT (in-container path) $3=DB host -> evidence line
    local name="$1" cert="$2" host="$3" envargs=() args=() mark cs logs st
    while IFS= read -r e; do [[ -n "$e" ]] && envargs+=(-e "$e"); done < <(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$MN" \
      | grep -vE '^(SSL_ROOT_CERT|PGPASSFILE|DB_SYNC_POSTGRES_CONNECTION_STRING)=')
    mapfile -t args < <(docker inspect -f '{{json .Config.Cmd}}' "$MN" | jq -r '.[]')
    cs="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$MN" | sed -n 's/^DB_SYNC_POSTGRES_CONNECTION_STRING=//p' | sed "s/@postgres:5432/@${host}:5432/")"
    mark=$(docker logs "$PG" 2>&1 | wc -l)
    docker run -d --name "$name" --network "$NET" --user 10001:10001 "${envargs[@]}" \
      -e "DB_SYNC_POSTGRES_CONNECTION_STRING=$cs" -e "SSL_ROOT_CERT=$cert" -e PGPASSFILE=/run/secrets/midnight/pgpass \
      -v "$SECRETS/midnight-neg/pgpass-any:/run/secrets/midnight/pgpass:ro" \
      -v "$SECRETS/midnight/postgres-ca.crt:/run/secrets/midnight/postgres-ca.crt:ro" \
      -v "$SECRETS/midnight-neg/rogue-ca.crt:/run/secrets/midnight/rogue-ca.crt:ro" \
      --tmpfs /node/chain:uid=10001,gid=10001,mode=0700 "$MN_IMAGE" "${args[@]}" >/dev/null || { echo "could-not-start"; return; }
    for _ in $(seq 1 45); do   # until it logs in, or exits / logs a connection error
      st="$(docker inspect -f '{{.State.Status}}' "$name")"
      [[ "$st" == exited ]] && break
      docker logs "$PG" 2>&1 | tail -n +$((mark + 1)) | grep -q 'connection authorized: user=midnight' && break
      docker logs "$name" 2>&1 | grep -v 'SSL mode' | grep -qE '^error:|Could not connect to database' && break
      sleep 2
    done
    logs="$(docker logs "$name" 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
    echo "authorized=$(docker logs "$PG" 2>&1 | tail -n +$((mark + 1)) | grep -c 'connection authorized: user=midnight')" \
         "$(grep -m1 -oE 'Database connection SSL mode: [A-Za-z]+' <<<"$logs" || echo 'no-ssl-mode-line')" \
         "| $(grep -v 'Database connection SSL mode' <<<"$logs" | grep -m1 -E '^error:|Could not connect to database|[Ee]rror' | sed 's/^.*\(Could not connect\)/\1/' | cut -c1-260)"
    docker rm -fv "$name" >/dev/null 2>&1
  }
  check M9 "control: copy of the node container with the correct CA and host logs in" \
    '^authorized=[1-9][0-9]* Database connection SSL mode: VerifyFull' \
    "$(node_clone "${PREFIX}-m9" /run/secrets/midnight/postgres-ca.crt postgres)"
  check M10 "node rejects a Postgres certificate from an untrusted CA" \
    '^authorized=0 Database connection SSL mode: VerifyFull \| .*([Cc]ertificate|UnknownIssuer|[Ii]ssuer|verify)' \
    "$(node_clone "${PREFIX}-m10" /run/secrets/midnight/rogue-ca.crt postgres)"
  check M11 "node rejects a host-name mismatch (connects by IP; certificate is for 'postgres')" \
    '^authorized=0 Database connection SSL mode: VerifyFull \| .*([Cc]ertificate|NotValidForName|[Hh]ost ?name|name|verify)' \
    "$(node_clone "${PREFIX}-m11" /run/secrets/midnight/postgres-ca.crt "$pg_ip")"
  say "# midnight-node log tail (container $state):"
  docker logs --tail 15 "$MN" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200 | while IFS= read -r l; do say "    $l"; done
fi

# ---- summary ----------------------------------------------------------------------------------
n_pass=0 n_fail=0 n_skip=0
for s in "${R_STATUS[@]}"; do case "$s" in PASS) n_pass=$((n_pass+1));; FAIL) n_fail=$((n_fail+1));; SKIP) n_skip=$((n_skip+1));; esac; done
say ""; say "==================== SUMMARY ===================="
say "PASS $n_pass   FAIL $n_fail   SKIP $n_skip"
for i in "${!R_STATUS[@]}"; do [[ "${R_STATUS[$i]}" == FAIL ]] && say "FAILED:   ${R_ID[$i]} ${R_DESC[$i]}"; done
if (( n_skip )); then
  say "SKIPPED (NOT VERIFIED): $(for i in "${!R_STATUS[@]}"; do [[ "${R_STATUS[$i]}" == SKIP ]] && printf '%s ' "${R_ID[$i]}"; done)"
  say "  reason: $skip_reason"
fi
if (( n_fail )); then result="FAIL$( ((n_skip)) && echo ", and $n_skip check(s) SKIPPED (not verified)")"; code=1
elif (( n_skip )); then result="INCOMPLETE - $n_skip check(s) skipped, see above"; code=4
else result="PASS"; code=0; fi
say "RESULT: $result"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### infra smoke test: $result"
    echo "| | Check | Result |"; echo "|---|---|---|"
    for i in "${!R_STATUS[@]}"; do echo "| ${R_ID[$i]} | ${R_DESC[$i]} | **${R_STATUS[$i]}** |"; done
    (( n_skip )) && echo && echo "> **${n_skip} check(s) SKIPPED, not verified:** $skip_reason"
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit "$code"

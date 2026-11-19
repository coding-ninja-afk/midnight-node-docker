#!/bin/bash
# Pre-creates the db-sync indexes midnight-node 2.1.101 would otherwise create itself at startup.
# Its runtime role `midnight` is read-only, so the node cannot run CREATE INDEX (it exits with
# "cannot execute CREATE INDEX in a read-only transaction"). The node skips any index that
# pg_indexes already lists, so this runs once, as the db-sync TABLE OWNER, before the node starts.
#
# Definitions: copied from midnight-node tag node-2.1.101 and checked against EVERY CREATE INDEX in
# that tag's non-test Rust source by infra/scripts/verify-index-defs.sh. They come from:
#   node/src/main_chain_follower.rs                                        idx_multi_asset_policy_name_hex
#   primitives/mainchain-follower/src/db/queries/cnight_observation.rs     9 indexes (cNight observation)
#   primitives/mainchain-follower/src/data_source/candidates_data_source/db_model.rs  and
#   partner-chains/toolkit/data-sources/db-sync/src/db_model.rs             (duplicates of the above)
# db-sync 13.7.1.0 already creates idx_block_block_no and idx_tx_block_id itself, with identical
# definitions; those are found "present and valid" and left alone.
#
# Safe to rerun:
#   - a VALID index with the expected definition is left alone;
#   - an INVALID leftover of an interrupted CONCURRENTLY build is dropped and rebuilt;
#   - an index with the right name but a DIFFERENT definition is an error, never silently accepted
#     (the node would skip it by name and run with the wrong index).
# Builds use CONCURRENTLY, so db-sync keeps writing meanwhile (each statement runs on its own,
# outside a transaction block, as CONCURRENTLY requires).
#
# Connection (libpq env):
#   one-shot container (Terraform):  PGHOST=postgres, POSTGRES_{DB,USER,PASSWORD}_FILE
#   inside the postgres container:   no PGHOST (unix socket), POSTGRES_{DB,USER}_FILE
# Exit: 0 all three indexes valid with the expected definitions; 1 anything else.
set -euo pipefail

log()  { echo "midnight-indexes: $*"; }
fail() { echo "midnight-indexes: ERROR: $*" >&2; exit 1; }

read_secret() {  # $1=path: must be readable and non-empty
  [[ -r "$1" ]] || fail "$1 is not readable by uid $(id -u)"
  local v; v="$(< "$1")"; [[ -n "$v" ]] || fail "$1 is empty"
  printf '%s' "$v"
}
PGDATABASE="$(read_secret "${POSTGRES_DB_FILE:?POSTGRES_DB_FILE is not set}")"
PGUSER="$(read_secret "${POSTGRES_USER_FILE:?POSTGRES_USER_FILE is not set}")"
export PGDATABASE PGUSER
if [[ -n "${PGHOST:-}" ]]; then
  # Network connection: password via a private pgpass in tmpfs, never via env or argv.
  pw="$(read_secret "${POSTGRES_PASSWORD_FILE:?POSTGRES_PASSWORD_FILE is required with PGHOST}")"
  PGPASSFILE="$(mktemp)"; export PGPASSFILE
  trap 'rm -f "$PGPASSFILE"' EXIT
  pw="${pw//\\/\\\\}"; pw="${pw//:/\\:}"   # pgpass escaping: backslash and colon
  printf '*:*:*:*:%s\n' "$pw" > "$PGPASSFILE"; chmod 600 "$PGPASSFILE"   # mktemp already made it 0600
  unset pw
  export PGSSLMODE="${PGSSLMODE:-require}"
fi

q() { psql -X -At -v ON_ERROR_STOP=1 -c "$1"; }

# name | CREATE statement (node source, plus CONCURRENTLY) | pg_get_indexdef on PostgreSQL 17 with
# db-sync 13.7.1.0 column types (policy/name are bytea domains, hence the ::bytea casts)
INDEXES=(
  "idx_multi_asset_policy_name_hex|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_multi_asset_policy_name_hex ON multi_asset ((encode(policy, 'hex')), (encode(name, 'hex')))|CREATE INDEX idx_multi_asset_policy_name_hex ON public.multi_asset USING btree (encode((policy)::bytea, 'hex'::text), encode((name)::bytea, 'hex'::text))"
  "idx_tx_out_address|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_out_address ON tx_out USING hash (address)|CREATE INDEX idx_tx_out_address ON public.tx_out USING hash (address)"
  "idx_ma_tx_out_ident|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_ident ON ma_tx_out(ident)|CREATE INDEX idx_ma_tx_out_ident ON public.ma_tx_out USING btree (ident)"
  "idx_ma_tx_out_id_ident|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ma_tx_out_id_ident ON ma_tx_out(tx_out_id, ident)|CREATE INDEX idx_ma_tx_out_id_ident ON public.ma_tx_out USING btree (tx_out_id, ident)"
  "idx_multi_asset_policy_name|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_multi_asset_policy_name ON multi_asset(policy, name)|CREATE INDEX idx_multi_asset_policy_name ON public.multi_asset USING btree (policy, name)"
  "idx_block_block_no|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_block_block_no ON block(block_no)|CREATE INDEX idx_block_block_no ON public.block USING btree (block_no)"
  "idx_tx_block_id|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_block_id ON tx(block_id)|CREATE INDEX idx_tx_block_id ON public.tx USING btree (block_id)"
  "idx_tx_out_tx_id|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_out_tx_id ON tx_out(tx_id)|CREATE INDEX idx_tx_out_tx_id ON public.tx_out USING btree (tx_id)"
  "idx_tx_out_data_hash|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_out_data_hash ON tx_out(data_hash)|CREATE INDEX idx_tx_out_data_hash ON public.tx_out USING btree (data_hash)"
  "idx_tx_in_tx_in_id|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_in_tx_in_id ON tx_in(tx_in_id)|CREATE INDEX idx_tx_in_tx_in_id ON public.tx_in USING btree (tx_in_id)"
  "idx_tx_in_tx_out_id_tx_out_index|CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_tx_in_tx_out_id_tx_out_index ON tx_in(tx_out_id, tx_out_index)|CREATE INDEX idx_tx_in_tx_out_id_tx_out_index ON public.tx_in USING btree (tx_out_id, tx_out_index)"
)

# db-sync must have created its schema (phase 2 only runs after DB Sync is READY).
TABLES="'block','tx','tx_out','tx_in','multi_asset','ma_tx_out'"
missing="$(q "SELECT string_agg(t, ', ') FROM unnest(ARRAY[$TABLES]) t WHERE to_regclass('public.' || t) IS NULL;")"
[[ -z "$missing" ]] || fail "db-sync tables missing: $missing (run this after DB Sync is READY)"

# Must be the table owner (or superuser): CREATE INDEX requires it.
owner_ok="$(q "SELECT bool_and(pg_has_role(current_user, c.relowner, 'USAGE')) FROM pg_class c WHERE c.oid IN (SELECT ('public.' || t)::regclass FROM unnest(ARRAY[$TABLES]) t);")"
[[ "$owner_ok" == t ]] || fail "user '$PGUSER' does not own the db-sync tables; run as db-sync's database user"

state_of() {  # $1=index name -> "absent" | "<valid t/f>|<schema>|<pg_get_indexdef>" ; >1 match is an error
  local rows
  rows="$(q "SELECT i.indisvalid::text || '|' || n.nspname || '|' || pg_get_indexdef(i.indexrelid)
               FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE c.relname = '$1';")"
  [[ -z "$rows" ]] && { echo absent; return; }
  (( $(wc -l <<<"$rows") == 1 )) || fail "index name $1 exists in more than one schema; the node checks by name only"
  echo "$rows"
}

for entry in "${INDEXES[@]}"; do
  IFS='|' read -r name create want <<<"$entry"
  st="$(state_of "$name")"
  if [[ "$st" != absent ]]; then
    IFS='|' read -r valid schema def <<<"$st"
    if [[ "$valid" == false ]]; then
      log "$name: INVALID leftover (interrupted concurrent build): dropping and rebuilding"
      q "DROP INDEX CONCURRENTLY IF EXISTS \"$schema\".\"$name\";" >/dev/null
      st=absent
    elif [[ "$def" != "$want" ]]; then
      fail "$name exists with a different definition:
    found:    $def
    expected: $want
  midnight-node would skip it by name; drop or rename it after checking where it came from"
    else
      log "$name: present and valid, definition matches: nothing to do"
      continue
    fi
  fi
  log "$name: creating (CONCURRENTLY; can take a while on large tables)"
  q "$create;" >/dev/null
  st="$(state_of "$name")"
  [[ "$st" == "true|public|$want" ]] || fail "$name after build: '$st' (expected valid with: $want)"
  log "$name: created, valid, definition matches"
done
log "all ${#INDEXES[@]} indexes present, valid and matching midnight-node 2.1.101"

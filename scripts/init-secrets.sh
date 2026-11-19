#!/usr/bin/env bash
# Create ./secrets/postgres_{db,user,password} for compose-partner-chains.yml.
#
# Never overwrites an existing file: Postgres only reads these values when it
# initialises an EMPTY data volume, so changing them later breaks db-sync's login
# (see RUNBOOK.md section 10 for the in-place password reset).
#
# Usage: scripts/init-secrets.sh [db_name] [db_user]   (defaults: cexplorer postgres)
set -euo pipefail
cd "$(dirname "$0")/.."

db_name="${1:-cexplorer}"
db_user="${2:-postgres}"

# Names are later interpolated into SQL (ALTER ROLE "<user>"), so accept only plain
# lower-case Postgres identifiers.
for v in "$db_name" "$db_user"; do
  if [[ ! "$v" =~ ^[a-z_][a-z0-9_]{0,62}$ ]]; then
    echo "error: '$v' is not a plain Postgres identifier ([a-z_][a-z0-9_]*, max 63 chars)" >&2
    exit 2
  fi
done

umask 077
mkdir -p secrets
chmod 700 secrets

write_if_missing() {  # $1=file  $2=value
  if [[ -e "secrets/$1" ]]; then
    echo "keep    secrets/$1 (already exists)"
  else
    printf '%s' "$2" > "secrets/$1"
    echo "created secrets/$1"
  fi
}

write_if_missing postgres_db   "$db_name"
write_if_missing postgres_user "$db_user"
# 32 hex chars (128 bits) from the kernel CSPRNG; written only if the file is missing, never echoed.
write_if_missing postgres_password "$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
chmod 600 secrets/postgres_db secrets/postgres_user secrets/postgres_password

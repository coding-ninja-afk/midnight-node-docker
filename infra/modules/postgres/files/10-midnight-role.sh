#!/bin/bash
# Runs once, as the postgres user (uid 999), when the data volume is first initialised.
# Creates the read-only role midnight-node connects with. The password is read from a file by
# psql itself (\set with backticks), so it never appears in argv or in the environment.
#
# The file must be readable by uid 999 and non-empty. Otherwise this script exits 1, which makes
# the image's entrypoint abort the initialisation, rather than letting psql carry on after a failed
# `cat` and create the role with NO password (smoke test O2/O3).
set -euo pipefail
: "${MIDNIGHT_DB_PASSWORD_FILE:?MIDNIGHT_DB_PASSWORD_FILE is not set}"

fail() {
  echo "10-midnight-role.sh: ERROR: $*" >&2
  echo "10-midnight-role.sh: refusing to create role 'midnight' without a usable password; initialisation aborted." >&2
  exit 1
}

pw_file="$MIDNIGHT_DB_PASSWORD_FILE"
[[ -e "$pw_file" ]] || fail "$pw_file does not exist"
[[ -r "$pw_file" ]] || fail "$pw_file is not readable by $(id -un) (uid $(id -u)); it must be owned by uid 999 (mode 0600) - see infra/README.md \"Secrets\""
# Non-empty after trimming whitespace (an all-whitespace file would also give an empty password).
[[ -n "$(tr -d '[:space:]' < "$pw_file")" ]] || fail "$pw_file is empty"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
\set pw \`cat ${pw_file}\`
CREATE ROLE midnight LOGIN PASSWORD :'pw';
ALTER ROLE midnight SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE "${POSTGRES_DB}" TO midnight;
GRANT USAGE ON SCHEMA public TO midnight;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO midnight;
-- db-sync creates its tables later, as POSTGRES_USER: grant on those too.
ALTER DEFAULT PRIVILEGES FOR ROLE "${POSTGRES_USER}" IN SCHEMA public GRANT SELECT ON TABLES TO midnight;
EOSQL

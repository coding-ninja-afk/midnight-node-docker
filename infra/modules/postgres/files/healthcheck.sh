#!/bin/bash
# Postgres container healthcheck (infra/modules/postgres). "Healthy" means more than "accepting
# connections": the read-only role midnight-node uses must exist and be usable.
#
# Why: if 10-midnight-role.sh aborts the first initialisation (missing/empty/unreadable password
# file), initdb has already populated PGDATA. When the container restarts, the image's entrypoint
# sees an existing database, skips initialisation, and Postgres runs normally WITHOUT the role.
# pg_isready alone would report that as healthy (smoke test R1-R2). This check keeps it unhealthy,
# so Terraform's wait and anything depending on the container's health fails visibly.
#
# Runs as the container's default user over the unix socket, as POSTGRES_USER (the superuser the
# image creates; needed to read pg_authid). Prints the reason on failure (docker inspect -> Health).
set -uo pipefail

user="$(cat /run/secrets/postgres_user 2>/dev/null)" || { echo "cannot read postgres_user"; exit 1; }
db="$(cat /run/secrets/postgres_db 2>/dev/null)"     || { echo "cannot read postgres_db"; exit 1; }

pg_isready -q -U "$user" -d "$db" || { echo "postgres not accepting connections"; exit 1; }

# One row of t/f flags; any 'f' (or no row) is unhealthy.
row="$(psql -X -At -U "$user" -d "$db" -v ON_ERROR_STOP=1 -c "
  SELECT r.rolcanlogin, a.rolpassword IS NOT NULL, NOT r.rolsuper,
         coalesce('default_transaction_read_only=on' = ANY (r.rolconfig), false),
         has_database_privilege(r.oid, current_database(), 'CONNECT'),
         has_schema_privilege(r.oid, 'public', 'USAGE'),
         EXISTS (SELECT 1 FROM pg_default_acl d
                  WHERE d.defaclrole = (SELECT oid FROM pg_roles WHERE rolname = current_user)
                    AND d.defaclobjtype = 'r'
                    AND EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) x
                                 WHERE x.grantee = r.oid AND x.privilege_type = 'SELECT'))
    FROM pg_roles r JOIN pg_authid a ON a.oid = r.oid
   WHERE r.rolname = 'midnight';" 2>&1)" || { echo "role check query failed: $row"; exit 1; }

[[ -n "$row" ]] || { echo "UNHEALTHY: role 'midnight' does not exist (initialisation did not complete; see infra/README.md 'Secrets')"; exit 1; }
labels=(can_login has_password not_superuser read_only_default connect_on_db usage_on_public default_select_on_new_tables)
IFS='|' read -r -a flags <<<"$row"
bad=()
for i in "${!labels[@]}"; do [[ "${flags[$i]:-f}" == t ]] || bad+=("${labels[$i]}"); done
if (( ${#bad[@]} )); then echo "UNHEALTHY: role 'midnight' is missing: ${bad[*]}"; exit 1; fi
echo "ok: accepting connections; role 'midnight' present, read-only, with password and grants"

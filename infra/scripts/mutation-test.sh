#!/usr/bin/env bash
# Proves the gates catch real mistakes: copies infra/ to a temp dir, applies one deliberate
# mistake at a time, and checks that at least the expected gate fails. Read-only for infra/.
# Usage (from infra/, after terraform init): scripts/mutation-test.sh [env]   (default preprod)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ENV="${1:-preprod}"
SRC="$PWD"
pass=0 fail=0

# name | file | python replacement (old => new) | gate expected to fail
MUTATIONS=(
  "postgres publishes 5432|modules/postgres/main.tf|  networks_advanced {\n    name    = var.internal_network\n    aliases = [\"postgres\"]\n  }=>  networks_advanced {\n    name    = var.internal_network\n    aliases = [\"postgres\"]\n  }\n  ports {\n    internal = 5432\n    external = 5432\n  }|test,checkov"
  "password in connection string|modules/midnight-node/main.tf|postgres://\${var.postgres_role}@=>postgres://\${var.postgres_role}:hunter2@|test"
  "RPC published on 0.0.0.0|modules/midnight-node/main.tf|    external = var.rpc_host_port\n    ip       = \"127.0.0.1\"=>    external = var.rpc_host_port\n    ip       = \"0.0.0.0\"|test"
  "midnight starts without the gate|modules/midnight-node/main.tf|  start        = var.start=>  start        = true|test"
  "indexer no longer waits for midnight|main.tf|  depends_on = [module.midnight_node]=>|order"
  "midnight-node no longer waits for its indexes|main.tf|  depends_on = [module.cardano_db_sync, module.midnight_db_indexes]=>  depends_on = [module.cardano_db_sync]|order"
  "secret written into state via upload|modules/midnight-indexer/main.tf|  networks_advanced {\n    name = var.edge_network\n  }=>  networks_advanced {\n    name = var.edge_network\n  }\n  upload {\n    file    = \"/run/secrets/indexer/secret\"\n    content = \"deadbeef\"\n  }|test,checkov"
  "image left unpinned|envs/$ENV.tfvars|midnightntwrk/midnight-node:2.1.101@sha256:0c1ad548d523c1109aa1f16daab1bf72dcb78c7e17b8a8c6d97424ad0eba7b8a=>midnightntwrk/midnight-node:latest|test"
)

for m in "${MUTATIONS[@]}"; do
  IFS='|' read -r name file repl gates <<<"$m"
  work="$(mktemp -d)"; cp -a "$SRC/." "$work/"
  python3 -I - "$work/$file" "$repl" <<'PY' || { echo "SETUP-ERROR  $name (pattern not found)"; fail=$((fail+1)); rm -rf "$work"; continue; }
import sys, pathlib
path, repl = sys.argv[1], sys.argv[2].encode().decode("unicode_escape")
old, new = repl.split("=>", 1)
p = pathlib.Path(path); s = p.read_text()
if old not in s: sys.exit(1)
p.write_text(s.replace(old, new, 1))
PY
  caught=()
  if [[ "$gates" == *test* ]]; then
    (cd "$work" && terraform test -no-color -var-file="envs/$ENV.tfvars" >/dev/null 2>&1) || caught+=(test)
  fi
  if [[ "$gates" == *checkov* ]]; then
    (cd "$work" && checkov --config-file .checkov.yaml >/dev/null 2>&1) || caught+=(checkov)
  fi
  if [[ "$gates" == *order* ]]; then
    (cd "$work" && scripts/check-order.sh >/dev/null 2>&1) || caught+=(order)
  fi
  expected=$(tr ',' ' ' <<<"$gates" | wc -w)
  if (( ${#caught[@]} == expected )); then
    echo "caught      $name  (by: ${caught[*]})"; pass=$((pass+1))
  else
    echo "NOT CAUGHT  $name  (expected: $gates, caught by: ${caught[*]:-none})"; fail=$((fail+1))
  fi
  rm -rf "$work"
done
echo; echo "$pass caught, $fail missed"
(( fail == 0 ))

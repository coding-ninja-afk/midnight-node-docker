#!/usr/bin/env bash
# Assert the start-up ordering is encoded in Terraform's dependency graph:
#   cardano-node -> cardano-db-sync -> index pre-creation -> midnight-node -> indexer
#   (and postgres -> db-sync, volume-init -> midnight-node). "A after B" = B is reachable from A
# in `terraform graph` (the graph is transitively reduced, so direct edges alone are not enough).
#
# Self-contained: works on a fresh checkout, and in CI after `init -backend=false` (where
# `terraform graph` refuses to run). It graphs a throwaway copy with a local backend and the
# committed lock file. A failing or empty graph is an error (exit 2), never a vacuous pass.
# Usage (from infra/): scripts/check-order.sh      Exit: 0 ok, 1 ordering wrong, 2 cannot graph
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar --exclude=./.terraform --exclude='./*.tfstate*' --exclude=./backend_override.tf -cf - . | tar -xf - -C "$work"
printf 'terraform {\n  backend "local" {}\n}\n' > "$work/backend_override.tf"
plugin_args=(); [[ -d .terraform/providers ]] && plugin_args=(-plugin-dir="$PWD/.terraform/providers")
if ! init_log="$(cd "$work" && terraform init -input=false -no-color -lockfile=readonly "${plugin_args[@]}" 2>&1)"; then
  echo "error: terraform init for the graph failed:" >&2; tail -5 <<<"$init_log" >&2; exit 2
fi
if ! graph="$(cd "$work" && terraform graph -no-color 2>&1)"; then
  echo "error: terraform graph failed:" >&2; head -8 <<<"$graph" >&2; exit 2
fi
grep -q -- '->' <<<"$graph" || { echo "error: terraform graph returned no edges" >&2; exit 2; }

python3 -I -c '
import re, sys
edges = {}
for a, b in re.findall(r"\"([^\"]+)\" -> \"([^\"]+)\"", sys.stdin.read()):
    edges.setdefault(a, set()).add(b)

def after(a, b):  # does a (transitively) depend on b?
    seen, todo = set(), [a]
    while todo:
        n = todo.pop()
        for m in edges.get(n, ()):
            if m == b:
                return True
            if m not in seen:
                seen.add(m); todo.append(m)
    return False

c = lambda m, r="this": f"module.{m}.docker_container.{r}"
must = [
    (c("cardano_db_sync"), c("cardano_node"), "db-sync after cardano-node"),
    (c("cardano_db_sync"), c("postgres"), "db-sync after postgres"),
    (c("midnight_node"), c("cardano_db_sync"), "midnight-node after db-sync"),
    (c("midnight_node"), c("midnight_node", "volume_init"), "midnight-node after volume ownership fix"),
    (c("midnight_db_indexes"), c("cardano_db_sync"), "index pre-creation after db-sync (needs its schema)"),
    (c("midnight_node"), c("midnight_db_indexes"), "midnight-node after index pre-creation"),
    (c("midnight_indexer"), c("midnight_node"), "indexer after midnight-node"),
]
must_not = [  # sanity: the check can fail, and nothing waits on the wrong thing
    (c("cardano_node"), c("midnight_node"), "cardano-node must not wait for midnight-node"),
    (c("midnight_node"), c("midnight_indexer"), "midnight-node must not wait for the indexer"),
    (c("cardano_db_sync"), c("midnight_db_indexes"), "db-sync must not wait for the index pre-creation"),
]
bad = 0
for a, b, label in must:
    ok = after(a, b); bad += not ok
    print(("ok    " if ok else "FAIL  ") + label)
for a, b, label in must_not:
    ok = not after(a, b); bad += not ok
    print(("ok    " if ok else "FAIL  ") + label)
sys.exit(1 if bad else 0)
' <<<"$graph"

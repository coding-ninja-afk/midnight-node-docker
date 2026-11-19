#!/usr/bin/env bash
# Assert the start-up ordering is encoded in Terraform's dependency graph:
#   cardano-node -> cardano-db-sync -> midnight-node -> indexer   (and postgres -> db-sync,
#   volume-init -> midnight-node). "A after B" = B is reachable from A in `terraform graph`
# (the graph is transitively reduced, so direct edges alone are not enough).
# Usage (from infra/, after terraform init): scripts/check-order.sh
set -euo pipefail
cd "$(dirname "$0")/.."

terraform graph -no-color | python3 -I -c '
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
'

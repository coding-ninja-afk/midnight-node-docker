#!/usr/bin/env bash
# Verify modules/midnight-db-indexes/files/midnight-indexes.sh against the PINNED midnight-node source.
#   1. The version comes from the midnight_node image pin in envs/*.tfvars (all envs must agree);
#      the source is the GitHub tarball of tag node-<version>.
#   2. EVERY "CREATE INDEX" string in the tag's non-test Rust source is collected (no hand-picked
#      file list: an earlier version read two files and missed eight indexes). The set and each
#      definition must match ours exactly, ignoring only our added CONCURRENTLY and whitespace.
#      A name defined differently in two places is a failure.
#   3. Each index must be guarded by a skip-if-present check (pg_indexes / index_exists) in the
#      source; that is what makes pre-creating them work with a read-only runtime role.
#   4. Any OTHER DDL the node sends (ALTER/CREATE TABLE, DROP, TRUNCATE...) is listed: a read-only
#      runtime role cannot run it, and pre-creation cannot help. Listed as NOTE (does not fail).
# Needs network access to codeload.github.com. Exit 0 = verified, 1 = mismatch, 2 = error.
# Usage (from infra/): scripts/verify-index-defs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

versions="$(grep -ohE 'midnightntwrk/midnight-node:[0-9][^@"]*' envs/*.tfvars | sort -u | sed 's/.*://')"
[[ -n "$versions" && $(wc -l <<<"$versions") -eq 1 ]] || { echo "error: envs must pin exactly one midnight-node version, found: ${versions:-none}" >&2; exit 2; }
tag="node-$versions"

src="$(mktemp -d)"; trap 'rm -rf "$src"' EXIT
curl -fsSL --max-time 300 "https://codeload.github.com/midnightntwrk/midnight-node/tar.gz/refs/tags/$tag" -o "$src/src.tgz" \
  || { echo "error: cannot download source tarball for $tag" >&2; exit 2; }
mkdir "$src/t"
if ! tar -xzf "$src/src.tgz" -C "$src/t" --wildcards '*.rs'; then echo "error: cannot unpack $tag" >&2; exit 2; fi
echo "# source: midnightntwrk/midnight-node@$tag ($(find "$src/t" -name '*.rs' | wc -l) .rs files)"

python3 -I - "$src/t" modules/midnight-db-indexes/files/midnight-indexes.sh <<'PY'
import pathlib, re, sys
root, ours_path = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
TEST = re.compile(r"(/tests?/|/benches/|_tests?\.rs$|/tests\.rs$|/test_|mock)")
files = [p for p in root.rglob("*.rs") if not TEST.search(str(p))]

def norm(s):
    s = re.sub(r"\s+", " ", s.replace("CONCURRENTLY ", ""))
    s = re.sub(r" \(", "(", s)                       # "ma_tx_out (a)" == "ma_tx_out(a)"
    return s.strip().rstrip(";").strip()

theirs, where, skips, other_ddl = {}, {}, set(), []
DDL = re.compile(r'"[^"\n]*?\b(ALTER TABLE|CREATE TABLE|DROP (?:TABLE|INDEX)|TRUNCATE|CREATE (?:OR REPLACE )?(?:FUNCTION|VIEW|TRIGGER))\b[^"\n]*"', re.I)
for f in files:
    text = f.read_text(errors="replace")
    rel = str(f.relative_to(root)).split("/", 1)[1]
    for m in re.finditer(r"(CREATE INDEX\s.*?)(?:;|\"#|\")", text, re.S):
        stmt = norm(m.group(1)); name = re.search(r"IF NOT EXISTS (\w+)", stmt)
        if not name: continue
        name = name.group(1)
        if name in theirs and theirs[name] != stmt:
            print(f"FAIL  {name}: defined differently in {where[name]} and {rel}\n        {theirs[name]}\n        {stmt}")
            sys.exit(1)
        theirs[name] = stmt; where.setdefault(name, rel)
    for m in re.finditer(r'(?:index_exists|create_index_if_not_exists)\(\s*(?:&?\w+),\s*"(\w+)"', text):
        skips.add(m.group(1))
    for m in re.finditer(r"pg_indexes[\s\S]{0,300}?indexname\s*=\s*'(\w+)'", text):
        skips.add(m.group(1))
    for m in DDL.finditer(text):
        line = text[:m.start()].count("\n") + 1
        other_ddl.append(f"{rel}:{line}: {m.group(0)[:110]}")

ours = {m.group(1): norm(m.group(2))
        for m in re.finditer(r'^\s*"(\w+)\|(CREATE INDEX[^|]+)\|', ours_path.read_text(), re.M)}
bad = 0
for name in sorted(set(theirs) | set(ours)):
    t, o = theirs.get(name), ours.get(name)
    if t is None:   print(f"FAIL  {name}: in midnight-indexes.sh but the node never creates it (extra)"); bad += 1; continue
    if o is None:   print(f"FAIL  {name}: created by the node ({where[name]}) but missing from midnight-indexes.sh"); bad += 1; continue
    if t != o:      print(f"FAIL  {name}: definition differs\n        source: {t}\n        ours:   {o}"); bad += 1; continue
    if name in skips: print(f"ok    {name}: identical; node skips it when present  [{where[name]}]")
    else:           print(f"FAIL  {name}: identical, but no skip-if-present check found in the source"); bad += 1
if not theirs: print("FAIL  no CREATE INDEX statements found: source layout changed?"); bad += 1
if other_ddl:
    print(f"\nNOTE  other DDL in the node source ({len(other_ddl)}): a read-only runtime role cannot run these, and pre-creation does not help:")
    for d in other_ddl: print(f"        {d}")
print(f"\n{'VERIFIED' if not bad else 'MISMATCH'}: {len(theirs)} index definition(s) in the node source, {len(ours)} in midnight-indexes.sh")
sys.exit(1 if bad else 0)
PY

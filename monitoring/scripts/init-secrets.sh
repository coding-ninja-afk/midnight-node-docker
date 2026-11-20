#!/usr/bin/env bash
# Create monitoring/secrets/grafana_admin_password (git-ignored) if missing, never overwriting it,
# and make it readable by Grafana only. Grafana runs as uid 472: with the file owned by you (0600)
# it cannot read it and silently starts with the DEFAULT admin/admin login (seen on 2026-11-20).
# Ownership is set as root in a throwaway container from the pinned Grafana image (no sudo).
set -euo pipefail
cd "$(dirname "$0")/.."
GRAFANA_IMAGE="grafana/grafana:13.3.0@sha256:488984b716c0862639f91a698adbe2862677a5a07bad42da5f03f3030883b205"
umask 077
mkdir -p secrets
if [[ -e secrets/grafana_admin_password ]]; then echo "keep    secrets/grafana_admin_password"
else od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > secrets/grafana_admin_password; echo "created secrets/grafana_admin_password"; fi
docker run --rm --network none --user 0:0 --entrypoint sh -v "$PWD/secrets:/s" "$GRAFANA_IMAGE" \
  -c 'chown 472:0 /s/grafana_admin_password && chmod 0400 /s/grafana_admin_password'
echo "owner set: uid 472 (grafana), mode 0400"

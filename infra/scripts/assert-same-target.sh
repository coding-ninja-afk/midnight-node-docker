#!/usr/bin/env bash
# Binds a saved Terraform plan to the target it was made against, and refuses to apply elsewhere.
#
# What must match between plan and apply:
#   1. the Docker DAEMON (unique ID) and ENDPOINT: the docker provider plans against whatever
#      the endpoint answers, and "unix:///var/run/docker.sock" is a different daemon on every machine;
#   2. the infra/ WORKDIR: modules bind-mount repo files via abspath(path.module), so the checkout
#      directory is baked into the saved plan as absolute host paths;
#   3. every HOST PATH the plan bind-mounts (config files and secrets) must exist on this host.
#      A missing bind-mount source is silently created by Docker as an EMPTY DIRECTORY, so a missing
#      secret would not fail the apply; this check makes it fail first.
#
# Usage:  assert-same-target.sh record RECORD TFPLAN    (plan job, after terraform plan -out=TFPLAN)
#         assert-same-target.sh check  RECORD TFPLAN    (apply job, before terraform apply TFPLAN)
# Run from anywhere; needs terraform (initialised infra/) and jq. Endpoint: TF_VAR_docker_host,
# else DOCKER_HOST, else the default socket. Host paths can only be verified on the Docker host
# itself, so a non-unix:// endpoint is refused.
# Exit: 0 same target; 1 mismatch / missing path; 2 usage error, unreachable daemon, unreadable plan.
set -euo pipefail

mode="${1:-}" record="${2:-}" tfplan="${3:-}"
[[ "$mode" =~ ^(record|check)$ && -n "$record" && -n "$tfplan" ]] || { echo "usage: $0 record|check RECORD TFPLAN" >&2; exit 2; }
infra="$(cd "$(dirname "$0")/.." && pwd -P)"
[[ "$record" = /* ]] || record="$PWD/$record"
[[ "$tfplan" = /* ]] || tfplan="$PWD/$tfplan"
host="${TF_VAR_docker_host:-${DOCKER_HOST:-unix:///var/run/docker.sock}}"

if ! info="$(docker -H "$host" info -f '{{.ID}} {{.Name}}' 2>&1)"; then
  echo "error: cannot reach the Docker daemon at $host: $(grep -m1 -v "^[[:space:]]*$" <<<"$info")" >&2; exit 2
fi
read -r id name <<<"$info"
[[ -n "${id:-}" ]] || { echo "error: the Docker daemon at $host reported no ID" >&2; exit 2; }
[[ "$host" == unix://* ]] || { echo "error: endpoint $host is not a local socket: host paths cannot be verified from this runner; run the live jobs on the Docker host" >&2; exit 2; }

# Bind-mount sources in the saved plan (config files under infra/, secrets under secrets_dir).
# Named-volume mounts have host_path "" (not null) in the plan JSON, hence the select().
[[ -r "$tfplan" ]] || { echo "error: cannot read plan $tfplan" >&2; exit 2; }
if ! paths="$(cd "$infra" && terraform show -json "$tfplan" | jq -r '[.resource_changes[]? | .change.after.volumes[]? | .host_path // empty | select(. != "")] | unique | .[]')"; then
  echo "error: could not read host paths from $tfplan" >&2; exit 2
fi

case "$mode" in
  record)
    { printf 'daemon_id=%s\nendpoint=%s\nname=%s\nworkdir=%s\n' "$id" "$host" "$name" "$infra"
      while IFS= read -r p; do [[ -n "$p" ]] && printf 'host_path=%s\n' "$p"; done <<<"$paths"; } > "$record"
    echo "recorded: daemon $id ($name) at $host, workdir $infra, $(grep -c '^host_path=' "$record") bind-mount paths" ;;
  check)
    [[ -r "$record" ]] || { echo "error: no target record $record next to the plan; refusing to apply" >&2; exit 2; }
    get() { sed -n "s/^$1=//p" "$record"; }
    bad=0
    if [[ "$(get daemon_id)" != "$id" || "$(get endpoint)" != "$host" ]]; then
      echo "MISMATCH daemon: plan made against $(get daemon_id) ($(get name)) at $(get endpoint); this job reaches $id ($name) at $host" >&2; bad=1
    fi
    if [[ "$(get workdir)" != "$infra" ]]; then
      echo "MISMATCH workdir: plan made in $(get workdir); this job runs in $infra (the plan's absolute bind-mount paths point at the other checkout)" >&2; bad=1
    fi
    if [[ "$(get host_path | sort)" != "$(sort <<<"$paths")" ]]; then
      echo "MISMATCH host paths: the plan file's bind-mount paths differ from those recorded with it (plan file replaced?)" >&2; bad=1
    fi
    missing=0
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      if [[ ! -e "$p" ]]; then echo "MISSING host path: $p (Docker would create it as an empty directory)" >&2; missing=$((missing + 1)); fi
    done <<<"$paths"
    (( missing )) && bad=1
    if (( bad )); then echo "error: refusing to apply: the plan was not made for this target. Re-plan on this runner." >&2; exit 1; fi
    echo "ok: same daemon ($id, $name, $host), same workdir ($infra), all $(grep -c . <<<"$paths") bind-mount paths exist" ;;
esac

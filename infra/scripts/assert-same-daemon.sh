#!/usr/bin/env bash
# Binds a saved Terraform plan to the Docker daemon it was made against.
#
# A plan made against one daemon must never be applied to another: the docker provider plans
# against whatever the endpoint answers (containers, images, networks), and "unix:///var/run/
# docker.sock" names a different daemon on every machine. The plan job records the daemon's
# unique ID next to the saved plan; the apply job checks it before `terraform apply`.
#
# Usage:  assert-same-daemon.sh record FILE    (after terraform plan)
#         assert-same-daemon.sh check  FILE    (before terraform apply)
# The endpoint is TF_VAR_docker_host (what Terraform uses), else DOCKER_HOST, else the default socket.
# Exit: 0 recorded / same daemon; 1 different daemon or endpoint; 2 usage error or daemon unreachable.
set -euo pipefail

mode="${1:-}" file="${2:-}"
[[ "$mode" =~ ^(record|check)$ && -n "$file" ]] || { echo "usage: $0 record|check FILE" >&2; exit 2; }
host="${TF_VAR_docker_host:-${DOCKER_HOST:-unix:///var/run/docker.sock}}"

if ! info="$(docker -H "$host" info -f '{{.ID}} {{.Name}}' 2>&1)"; then
  echo "error: cannot reach the Docker daemon at $host: $(grep -m1 -v "^[[:space:]]*$" <<<"$info")" >&2; exit 2
fi
read -r id name <<<"$info"
[[ -n "${id:-}" ]] || { echo "error: the Docker daemon at $host reported no ID" >&2; exit 2; }

case "$mode" in
  record)
    printf 'daemon_id=%s\nendpoint=%s\nname=%s\n' "$id" "$host" "$name" > "$file"
    echo "recorded: plan made against daemon $id ($name) at $host" ;;
  check)
    [[ -r "$file" ]] || { echo "error: no daemon record $file next to the plan; refusing to apply" >&2; exit 2; }
    want_id="$(sed -n 's/^daemon_id=//p' "$file")"; want_host="$(sed -n 's/^endpoint=//p' "$file")"
    want_name="$(sed -n 's/^name=//p' "$file")"
    if [[ "$want_id" != "$id" || "$want_host" != "$host" ]]; then
      echo "error: refusing to apply: the plan was made against daemon $want_id ($want_name) at $want_host," >&2
      echo "       but this job talks to daemon $id ($name) at $host. Re-plan on this target." >&2
      exit 1
    fi
    echo "ok: applying on the same daemon the plan was made against ($id, $name, $host)" ;;
esac

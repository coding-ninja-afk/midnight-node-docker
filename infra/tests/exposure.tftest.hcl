# Network exposure and secret handling. Run per environment:
#   terraform test -var-file=envs/<env>.tfvars
# The mock provider means no Docker daemon is needed; assertions use plan-time values.
mock_provider "docker" {}

run "postgres_not_reachable_from_outside" {
  command = plan

  assert {
    condition     = length(output.container_specs.postgres.ports) == 0
    error_message = "Postgres must not publish any port."
  }
  assert {
    condition     = output.container_specs.postgres.networks == [output.networks.internal.name]
    error_message = "Postgres must be attached to the internal network only."
  }
  assert {
    condition     = output.networks.internal.internal == true
    error_message = "The internal network must be internal = true (no egress, no published ports)."
  }
}

run "only_p2p_ports_are_public" {
  command = plan

  # Every published port is either a P2P port or bound to loopback.
  assert {
    condition = alltrue(flatten([
      for c in values(output.container_specs) : [
        for p in c.ports : p.ip == "127.0.0.1" || contains([3001, 30333], p.internal)
      ]
    ]))
    error_message = "Only P2P ports (3001, 30333) may be published beyond 127.0.0.1."
  }
  assert {
    condition = alltrue([
      for p in output.container_specs.midnight_node.ports : p.ip == "127.0.0.1" if p.internal == 9944
      ]) && anytrue([
      for p in output.container_specs.midnight_node.ports : p.internal == 9944
    ])
    error_message = "midnight-node RPC (9944) must be published on 127.0.0.1 only."
  }
  assert {
    condition     = alltrue([for p in output.container_specs.midnight_indexer.ports : p.ip == "127.0.0.1"])
    error_message = "The indexer API must be published on 127.0.0.1 only."
  }
  assert {
    condition     = length(output.container_specs.cardano_db_sync.ports) == 0
    error_message = "cardano-db-sync must not publish any port."
  }
  assert {
    condition     = output.networks.edge.options["com.docker.network.bridge.enable_ip_masquerade"] == "false"
    error_message = "The edge network must not NAT outbound traffic."
  }
}

run "no_secret_values_in_config_or_state" {
  command = plan

  # Secret-looking variables must be *_FILE paths, never values.
  assert {
    condition = alltrue(flatten([
      for c in values(output.container_specs) : [
        for e in c.env : endswith(split("=", e)[0], "_FILE")
        if can(regex("(?i)(password|secret|seed|token|blockfrost|_key)", split("=", e)[0]))
      ]
    ]))
    error_message = "Secret-looking env vars must be *_FILE paths."
  }
  # No credentials embedded in any URL.
  assert {
    condition = alltrue(flatten([
      for c in values(output.container_specs) : [for e in c.env : !can(regex("://[^/@:]+:[^/@]+@", e))]
    ]))
    error_message = "Connection strings must not contain a password (use PGPASSFILE)."
  }
  # upload {} would put file content into state.
  assert {
    condition     = alltrue([for c in values(output.container_specs) : c.uploads == 0])
    error_message = "No upload blocks: their content is stored in Terraform state."
  }
  assert {
    condition     = alltrue(flatten([for c in values(output.container_specs) : [for m in c.host_mounts : m.read_only]]))
    error_message = "All host-path mounts (secrets, config) must be read-only."
  }
}

run "midnight_db_connection_is_tls_and_least_privilege" {
  command = plan

  assert {
    condition     = anytrue([for e in output.container_specs.midnight_node.env : startswith(e, "DB_SYNC_POSTGRES_CONNECTION_STRING=postgres://midnight@") && strcontains(e, "sslmode=verify-full")])
    error_message = "midnight-node must connect as the read-only 'midnight' role with sslmode=verify-full."
  }
  assert {
    condition     = contains(output.container_specs.midnight_node.env, "SSL_ROOT_CERT=/run/secrets/midnight/postgres-ca.crt")
    error_message = "midnight-node must set SSL_ROOT_CERT: without it the node uses PgSslMode::Require and does not verify the Postgres certificate or host name."
  }
  assert {
    condition     = contains(output.container_specs.postgres.command, "ssl=on")
    error_message = "Postgres must run with ssl=on."
  }
  assert {
    condition     = contains(output.container_specs.postgres.healthcheck, "/usr/local/bin/mn-pg-healthcheck.sh")
    error_message = "Postgres health must include the midnight-role check, not just pg_isready (a failed first init would otherwise restart as healthy)."
  }
  assert {
    condition     = output.container_specs.midnight_node.user == "10001:10001"
    error_message = "midnight-node must run as uid 10001 (its image entrypoint never drops root)."
  }
  assert {
    condition     = contains(output.container_specs.midnight_node.cap_drop, "ALL") && contains(output.container_specs.midnight_node.security_opts, "no-new-privileges:true")
    error_message = "midnight-node must drop all capabilities and set no-new-privileges."
  }
  assert {
    condition     = contains(output.container_specs.midnight_node.command, "Safe")
    error_message = "midnight-node RPC must be --rpc-methods Safe."
  }
}

run "images_pinned_to_documented_versions" {
  command = plan

  assert {
    condition     = alltrue([for c in values(output.container_specs) : can(regex("@sha256:[0-9a-f]{64}$", c.image)) if can(c.image)])
    error_message = "Every image must be pinned by digest."
  }
  assert {
    condition = alltrue([
      strcontains(output.container_specs.cardano_node.image, "cardano-node:11.0.1@"),
      strcontains(output.container_specs.cardano_db_sync.image, "cardano-db-sync:13.7.1.0@"),
      strcontains(output.container_specs.postgres.image, "postgres:17.12-bookworm@"),
      strcontains(output.container_specs.midnight_node.image, "midnight-node:2.1.101@"),
      strcontains(output.container_specs.midnight_indexer.image, "indexer-standalone:4.4.101@"),
    ])
    error_message = "Image versions must match RUNBOOK.md section 2."
  }
}

run "never_collides_with_the_hand_built_stack" {
  command = plan

  assert {
    condition     = alltrue([for c in values(output.container_specs) : startswith(c.name, "mn-${var.network}-")])
    error_message = "Every container name must start with mn-<network>-."
  }
  assert {
    condition     = alltrue([for v in values(output.volumes) : startswith(v.name, "mn-${var.network}-") && !startswith(v.name, "midnight-preprod")])
    error_message = "Volumes must never reuse the live compose stack's midnight-preprod_* names."
  }
}

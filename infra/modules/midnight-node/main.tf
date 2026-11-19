locals {
  name      = "${var.common.prefix}-midnight-node"
  base_path = "/node/chain"

  # Password-less URL: sqlx reads the password from PGPASSFILE (sqlx-postgres 0.8.6
  # parse_from_url -> apply_pgpass). The sslmode/sslrootcert here are kept for other libpq-style
  # clients; midnight-node itself takes TLS verification from SSL_ROOT_CERT (below).
  connection_string = "postgres://${var.postgres_role}@${var.postgres_host}:5432/${var.postgres_db}?sslmode=verify-full&sslrootcert=/run/secrets/midnight/postgres-ca.crt"

  key_env = var.validator_keys_enabled ? [
    "VALIDATOR=true",
    "AURA_SEED_FILE=/run/secrets/midnight/keys/aura.seed",
    "GRANDPA_SEED_FILE=/run/secrets/midnight/keys/grandpa.seed",
    "CROSS_CHAIN_SEED_FILE=/run/secrets/midnight/keys/cross_chain.seed",
    "NODE_KEY_FILE=/run/secrets/midnight/keys/node.key",
  ] : []

  secret_mounts = merge(
    {
      "pgpass"          = "/run/secrets/midnight/pgpass"
      "postgres-ca.crt" = "/run/secrets/midnight/postgres-ca.crt"
    },
    var.validator_keys_enabled ? { "keys" = "/run/secrets/midnight/keys" } : {},
  )

  args = concat(
    [
      "--chain", var.chain_spec,
      "--base-path", local.base_path,
      "--name", var.node_name,
      "--port", "30333",
      # RPC listens on the container's interfaces so the indexer can reach it over the internal
      # network; the host publishes it on 127.0.0.1 only, and only safe methods are exposed.
      "--rpc-port", "9944",
      "--rpc-external",
      "--rpc-methods", "Safe",
      # Metrics: reachable on the internal network only (not published).
      "--prometheus-port", "9615",
      "--prometheus-external",
    ],
    flatten([for b in var.bootnodes : ["--bootnodes", b]]),
    var.extra_args,
  )
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "data" {
  name = "${local.name}-data"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-node", "mn.storage-gb" = tostring(var.storage_gb) })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# One-shot: a new named volume is root-owned and the base path does not exist in the image, so
# the non-root node could not create its database. Runs to completion (attach) before the node
# container is created. Not recursive: everything below is written by the node itself.
resource "docker_container" "volume_init" {
  name       = "${local.name}-volume-init"
  image      = docker_image.this.image_id
  user       = "0:0"
  entrypoint = ["/bin/sh", "-c"]
  command    = ["chown ${var.run_as} ${local.base_path} && chmod 0700 ${local.base_path}"]
  env        = [] # explicit, so it is known at plan time (checked by tests)
  attach     = true
  must_run   = false
  restart    = "no"
  log_driver = "json-file"
  log_opts   = var.common.log_opts

  network_mode = "none"

  volumes {
    volume_name    = docker_volume.data.name
    container_path = local.base_path
  }

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-node-init" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "this" {
  name    = local.name
  image   = docker_image.this.image_id
  user    = var.run_as
  restart = "unless-stopped"
  command = local.args

  # Phase 2 gate: created in phase 1, started (and waited on) only when start = true.
  start        = var.start
  must_run     = var.start
  wait         = var.start
  wait_timeout = 300

  env = concat(
    [
      "CFG_PRESET=${var.cfg_preset}",
      "CARDANO_SECURITY_PARAMETER=${var.cardano_security_parameter}",
      "DB_SYNC_POSTGRES_CONNECTION_STRING=${local.connection_string}",
      # The node ignores sslmode/sslrootcert in the URL and builds its own TLS options: only
      # ssl_root_cert (env SSL_ROOT_CERT) turns on PgSslMode::VerifyFull, i.e. CA + hostname
      # checks (node/src/main_chain_follower.rs, node-2.1.101). Without it: Require, no checks.
      "SSL_ROOT_CERT=/run/secrets/midnight/postgres-ca.crt",
      "PGPASSFILE=/run/secrets/midnight/pgpass",
    ],
    local.key_env,
  )

  networks_advanced {
    name = var.p2p_network
  }

  networks_advanced {
    name    = var.internal_network
    aliases = ["midnight-node"]
  }

  ports {
    internal = 30333
    external = var.p2p_host_port
    ip       = "0.0.0.0"
    protocol = "tcp"
  }

  ports {
    internal = 9944
    external = var.rpc_host_port
    ip       = "127.0.0.1"
    protocol = "tcp"
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = local.base_path
  }

  dynamic "volumes" {
    for_each = local.secret_mounts
    content {
      host_path      = "${var.secrets_dir}/${volumes.key}"
      container_path = volumes.value
      read_only      = true
    }
  }

  # Healthy = RPC answers system_health (image ships curl). Readiness to validate is a separate,
  # stricter check: scripts/midnight-height-check.sh (output midnight_readiness_check).
  healthcheck {
    test         = ["CMD-SHELL", "curl -fsS -m 5 -H 'Content-Type: application/json' -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' http://127.0.0.1:9944 >/dev/null"]
    interval     = "30s"
    timeout      = "10s"
    retries      = 5
    start_period = "2m"
  }

  capabilities {
    drop = ["ALL"]
  }
  security_opts = ["no-new-privileges:true"]

  stop_timeout          = 120
  destroy_grace_seconds = 120
  log_driver            = "json-file"
  log_opts              = var.common.log_opts

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-node", "mn.dbsync-ready-at" = var.gate_evidence })
    content {
      label = labels.key
      value = labels.value
    }
  }

  depends_on = [docker_container.volume_init]
}

# indexer-standalone 4.4.101: chain, wallet, SPO indexers and the GraphQL API in one process,
# with in-process SQLite at /data (indexer-standalone/config.yaml at tag v4.4.101).
locals {
  name = "${var.common.prefix}-midnight-indexer"
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "data" {
  name = "${local.name}-data"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-indexer", "mn.storage-gb" = tostring(var.storage_gb) })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "this" {
  name    = local.name
  image   = docker_image.this.image_id
  restart = "unless-stopped"

  # Same gate as midnight-node; root module also depends_on the node module, which waits for
  # the node's RPC healthcheck when started.
  start    = var.start
  must_run = var.start
  wait     = var.start

  # *_FILE variants: the indexer reads the value into config and never writes it back into the
  # process environment (midnight-indexer README, "Sourcing Secrets from Files").
  env = [
    "APP__APPLICATION__NETWORK_ID=${var.network_id}",
    "APP__INFRA__NODE__URL=${var.node_ws_url}",
    "APP__INFRA__SPO_NODE__URL=${var.node_ws_url}",
    "APP__INFRA__SECRET_FILE=/run/secrets/indexer/secret",
    "APP__INFRA__SPO_NODE__BLOCKFROST_ID_FILE=/run/secrets/indexer/blockfrost_id",
  ]

  networks_advanced {
    name = var.internal_network
  }

  networks_advanced {
    name = var.edge_network
  }

  ports {
    internal = 8088
    external = var.api_host_port
    ip       = "127.0.0.1"
    protocol = "tcp"
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/data"
  }

  volumes {
    host_path      = "${var.secrets_dir}/secret"
    container_path = "/run/secrets/indexer/secret"
    read_only      = true
  }

  volumes {
    host_path      = "${var.secrets_dir}/blockfrost_id"
    container_path = "/run/secrets/indexer/blockfrost_id"
    read_only      = true
  }

  # The image's entrypoint creates this file while the indexer process runs.
  healthcheck {
    test         = ["CMD-SHELL", "test -f /var/run/indexer-standalone/running"]
    interval     = "30s"
    timeout      = "5s"
    retries      = 3
    start_period = "1m"
  }

  capabilities {
    drop = ["ALL"]
  }
  security_opts = ["no-new-privileges:true"]

  stop_timeout          = 60
  destroy_grace_seconds = 60
  log_driver            = "json-file"
  log_opts              = var.common.log_opts

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-indexer" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

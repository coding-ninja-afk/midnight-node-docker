locals {
  name = "${var.common.prefix}-cardano-node"
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "data" {
  name = "${local.name}-data"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "cardano-node", "mn.storage-gb" = tostring(var.storage_gb) })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# Shared with cardano-db-sync: carries the node's unix socket.
resource "docker_volume" "ipc" {
  name = "${local.name}-ipc"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "cardano-node" })
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

  env = [
    "NETWORK=${var.network}",
    "CARDANO_NODE_SOCKET_PATH=/ipc/node.socket",
  ]

  networks_advanced {
    name = var.p2p_network
  }

  ports {
    internal = 3001
    external = var.p2p_host_port
    ip       = "0.0.0.0"
    protocol = "tcp"
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/data"
  }

  volumes {
    volume_name    = docker_volume.ipc.name
    container_path = "/ipc"
  }

  healthcheck {
    test         = ["CMD-SHELL", "test -S /ipc/node.socket"]
    interval     = "30s"
    timeout      = "5s"
    retries      = 5
    start_period = "10m"
  }

  wait                  = true
  wait_timeout          = var.wait_timeout
  stop_timeout          = 120
  destroy_grace_seconds = 120
  log_driver            = "json-file"
  log_opts              = var.common.log_opts

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "cardano-node" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

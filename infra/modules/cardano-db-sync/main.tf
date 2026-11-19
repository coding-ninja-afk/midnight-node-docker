locals {
  name = "${var.common.prefix}-cardano-db-sync"
  # Only the three files db-sync needs; it never sees the midnight role password or TLS key.
  secret_files = ["postgres_db", "postgres_user", "postgres_password"]
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "state" {
  name = "${local.name}-state"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "cardano-db-sync", "mn.storage-gb" = tostring(var.storage_gb) })
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

  # The image reads /run/secrets/postgres_{db,user,password} itself.
  env = [
    "NETWORK=${var.network}",
    "POSTGRES_HOST=${var.postgres_host}",
    "POSTGRES_PORT=5432",
  ]

  networks_advanced {
    name = var.internal_network
  }

  dynamic "networks_advanced" {
    for_each = var.egress_network == null ? [] : [var.egress_network]
    content {
      name = networks_advanced.value
    }
  }

  volumes {
    volume_name    = var.ipc_volume
    container_path = "/node-ipc"
  }

  volumes {
    volume_name    = docker_volume.state.name
    container_path = "/var/lib/cexplorer"
  }

  dynamic "volumes" {
    for_each = toset(local.secret_files)
    content {
      host_path      = "${var.secrets_dir}/${volumes.value}"
      container_path = "/run/secrets/${volumes.value}"
      read_only      = true
    }
  }

  stop_timeout          = 60
  destroy_grace_seconds = 60
  log_driver            = "json-file"
  log_opts              = var.common.log_opts

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "cardano-db-sync" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

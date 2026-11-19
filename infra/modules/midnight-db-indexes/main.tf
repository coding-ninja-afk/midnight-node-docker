# Phase 2 only (the root module sets count = midnight_start ? 1 : 0), after cardano-db-sync and
# before midnight-node: pre-create the 11 db-sync indexes midnight-node 2.1.101 would otherwise try
# to create at startup with its read-only role (it skips indexes pg_indexes already lists).
# Runs files/midnight-indexes.sh once, as the db-sync TABLE OWNER, over TLS on the internal network.
# The script is idempotent and verifies every definition (see infra/scripts/verify-index-defs.sh);
# a non-zero exit fails the apply through the postcondition. midnight-node's role stays read-only.
locals {
  name = "${var.common.prefix}-midnight-db-indexes"
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_container" "this" {
  name       = local.name
  image      = docker_image.this.image_id
  entrypoint = ["/bin/bash", "/usr/local/bin/midnight-indexes.sh"]
  attach     = true # run to completion during apply
  must_run   = false
  restart    = "no"
  log_driver = "json-file"
  log_opts   = var.common.log_opts

  env = [
    "PGHOST=${var.postgres_host}",
    "PGPORT=5432",
    "POSTGRES_DB_FILE=/run/secrets/postgres_db",
    "POSTGRES_USER_FILE=/run/secrets/postgres_user",
    "POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password",
  ]

  networks_advanced {
    name = var.internal_network
  }

  dynamic "volumes" {
    for_each = toset(["postgres_db", "postgres_user", "postgres_password"])
    content {
      host_path      = "${var.secrets_dir}/${volumes.value}"
      container_path = "/run/secrets/${volumes.value}"
      read_only      = true
    }
  }

  volumes {
    host_path      = abspath("${path.module}/files/midnight-indexes.sh")
    container_path = "/usr/local/bin/midnight-indexes.sh"
    read_only      = true
  }

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "midnight-db-indexes" })
    content {
      label = labels.key
      value = labels.value
    }
  }

  timeouts {
    create = var.create_timeout
  }

  lifecycle {
    postcondition {
      condition     = self.exit_code == 0
      error_message = "midnight-indexes.sh failed (exit ${coalesce(self.exit_code, -1)}): see `docker logs ${local.name}`. midnight-node must not start without these indexes."
    }
  }
}

locals {
  name = "${var.common.prefix}-postgres"

  # Secret files: bind-mounted read-only by path. Values never enter Terraform config or state.
  secret_mounts = {
    "postgres_db"          = "/run/secrets/postgres_db"
    "postgres_user"        = "/run/secrets/postgres_user"
    "postgres_password"    = "/run/secrets/postgres_password"
    "midnight_db_password" = "/run/secrets/midnight_db_password"
    "tls/server.crt"       = "/run/secrets/tls/server.crt"
    "tls/server.key"       = "/run/secrets/tls/server.key"
  }

  config_mounts = {
    "pg_hba.conf"         = "/etc/postgresql/pg_hba.conf"
    "10-midnight-role.sh" = "/docker-entrypoint-initdb.d/10-midnight-role.sh"
    "healthcheck.sh"      = "/usr/local/bin/mn-pg-healthcheck.sh"
  }

  command = concat(
    [
      "postgres",
      "-c", "ssl=on",
      "-c", "ssl_cert_file=/run/secrets/tls/server.crt",
      "-c", "ssl_key_file=/run/secrets/tls/server.key",
      "-c", "ssl_min_protocol_version=TLSv1.2",
      "-c", "hba_file=/etc/postgresql/pg_hba.conf",
      "-c", "password_encryption=scram-sha-256", # checkov:skip=CKV_SECRET_6:setting name (hash algorithm), not a credential
    ],
    flatten([for k in sort(keys(var.tuning)) : ["-c", "${k}=${var.tuning[k]}"]]),
  )
}

resource "docker_image" "this" {
  name         = var.image
  keep_locally = true
}

resource "docker_volume" "data" {
  name = "${local.name}-data"

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "postgres", "mn.storage-gb" = tostring(var.storage_gb) })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "this" {
  name     = local.name
  image    = docker_image.this.image_id
  restart  = "unless-stopped"
  command  = local.command
  shm_size = 1024 # MB, as in the live stack

  env = [
    "POSTGRES_DB_FILE=/run/secrets/postgres_db",
    "POSTGRES_USER_FILE=/run/secrets/postgres_user",
    "POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password",
    "MIDNIGHT_DB_PASSWORD_FILE=/run/secrets/midnight_db_password",
  ]

  # Internal network only: no published ports, no egress.
  networks_advanced {
    name    = var.internal_network
    aliases = ["postgres"]
  }

  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/var/lib/postgresql/data"
  }

  dynamic "volumes" {
    for_each = local.secret_mounts
    content {
      host_path      = "${var.secrets_dir}/${volumes.key}"
      container_path = volumes.value
      read_only      = true
    }
  }

  dynamic "volumes" {
    for_each = local.config_mounts
    content {
      host_path      = abspath("${path.module}/files/${volumes.key}")
      container_path = volumes.value
      read_only      = true
    }
  }

  # Healthy = accepting connections AND the read-only role `midnight` exists with its password and
  # grants (files/healthcheck.sh). A first init aborted by 10-midnight-role.sh leaves PGDATA
  # populated; after a restart Postgres would run without the role and pg_isready alone would
  # still say healthy (smoke test R1-R2).
  healthcheck {
    test         = ["CMD", "/bin/bash", "/usr/local/bin/mn-pg-healthcheck.sh"]
    interval     = "10s"
    timeout      = "5s"
    retries      = 10
    start_period = "30s"
  }

  wait                  = true
  wait_timeout          = 180
  stop_timeout          = 120
  destroy_grace_seconds = 120
  log_driver            = "json-file"
  log_opts              = var.common.log_opts

  dynamic "labels" {
    for_each = merge(var.common.labels, { "mn.component" = "postgres" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}


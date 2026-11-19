variable "common" {
  description = "Shared settings from the root module: prefix, labels, log_opts."
  type = object({
    prefix   = string
    labels   = map(string)
    log_opts = map(string)
  })
}

variable "image" {
  description = "PostgreSQL image, pinned by digest."
  type        = string
}

variable "storage_gb" {
  description = "Planned size of the data volume (label only on Docker)."
  type        = number
}

variable "internal_network" {
  description = "Name of the internal network. Postgres is attached to nothing else."
  type        = string
}

variable "secrets_dir" {
  description = "Host directory with postgres_db, postgres_user, postgres_password, midnight_db_password and tls/{server.crt,server.key}; files owned by uid 999, mode 0600."
  type        = string
}

variable "tuning" {
  description = "PostgreSQL settings passed as -c key=value."
  type        = map(string)
  default     = {}
}


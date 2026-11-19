variable "common" {
  description = "Shared settings from the root module: prefix, labels, log_opts."
  type = object({
    prefix   = string
    labels   = map(string)
    log_opts = map(string)
  })
}

variable "image" {
  description = "PostgreSQL client image (the same digest-pinned image as the postgres module)."
  type        = string
}

variable "internal_network" {
  description = "Internal network, to reach Postgres."
  type        = string
}

variable "postgres_host" {
  description = "Postgres hostname on the internal network."
  type        = string
}

variable "secrets_dir" {
  description = "Host directory with the db-sync owner's postgres_db, postgres_user, postgres_password."
  type        = string
}

variable "create_timeout" {
  description = "Upper bound for the index builds (tx_out/tx_in are large: minutes on PreProd, much longer on Mainnet)."
  type        = string
  default     = "60m"
}

variable "common" {
  description = "Shared settings from the root module: prefix, labels, log_opts."
  type = object({
    prefix   = string
    labels   = map(string)
    log_opts = map(string)
  })
}

variable "image" {
  description = "Container image, pinned by digest."
  type        = string
}

variable "storage_gb" {
  description = "Planned size of the data volume (label only on Docker)."
  type        = number
}

variable "network" {
  description = "Cardano network name (the image's NETWORK env)."
  type        = string
}

variable "internal_network" {
  description = "Internal network, to reach Postgres."
  type        = string
}

variable "egress_network" {
  description = "Optional network with egress (off-chain pool metadata). null = internal only."
  type        = string
  default     = null
}

variable "ipc_volume" {
  description = "cardano-node IPC volume (node.socket)."
  type        = string
}

variable "postgres_host" {
  description = "Postgres hostname on the internal network."
  type        = string
}

variable "secrets_dir" {
  description = "Host directory with postgres_db, postgres_user, postgres_password."
  type        = string
}

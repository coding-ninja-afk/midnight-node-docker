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

variable "p2p_network" {
  description = "Network with egress where the P2P port is published."
  type        = string
}

variable "p2p_host_port" {
  description = "Host port for Cardano P2P (container 3001)."
  type        = number
}

variable "wait_timeout" {
  description = "Seconds to wait for the socket healthcheck. Raise when restoring a large snapshot (ledger replay)."
  type        = number
  default     = 900
}

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

variable "start" {
  description = "Phase-2 switch: false creates the container without starting it."
  type        = bool
}

variable "network_id" {
  description = "APP__APPLICATION__NETWORK_ID (image default 'undeployed')."
  type        = string
}

variable "node_ws_url" {
  description = "midnight-node websocket URL on the internal network."
  type        = string
}

variable "internal_network" {
  description = "Internal network, to reach midnight-node."
  type        = string
}

variable "edge_network" {
  description = "Loopback-publishing network without outbound NAT."
  type        = string
}

variable "api_host_port" {
  description = "Host port for the GraphQL API (container 8088), published on 127.0.0.1 only."
  type        = number
}

variable "secrets_dir" {
  description = "Host directory with secret (hex 32 bytes) and blockfrost_id; owned by uid 10001, mode 0400."
  type        = string
}

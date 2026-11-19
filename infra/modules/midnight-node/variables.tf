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

variable "gate_evidence" {
  description = "UTC timestamp of the DB Sync READY run that cleared phase 2; recorded as a container label."
  type        = string
  default     = ""
}

variable "cfg_preset" {
  description = "CFG_PRESET for the node."
  type        = string
}

variable "chain_spec" {
  description = "Raw chain spec path inside the image (/res/<network>/chain-spec-raw.json)."
  type        = string
}

variable "cardano_security_parameter" {
  description = "CARDANO_SECURITY_PARAMETER."
  type        = number
}

variable "node_name" {
  description = "Node name (--name)."
  type        = string
}

variable "bootnodes" {
  description = "Bootnode multiaddrs."
  type        = list(string)
  default     = []
}

variable "extra_args" {
  description = "Extra CLI arguments."
  type        = list(string)
  default     = []
}

variable "validator_keys_enabled" {
  description = "Mount keys/{aura,grandpa,cross_chain}.seed and keys/node.key and set VALIDATOR=true."
  type        = bool
  default     = false
}

variable "p2p_network" {
  description = "Network with egress where P2P and loopback RPC are published."
  type        = string
}

variable "internal_network" {
  description = "Internal network, to reach Postgres and serve the indexer."
  type        = string
}

variable "p2p_host_port" {
  description = "Host port for Midnight P2P (container 30333), published on 0.0.0.0."
  type        = number
}

variable "rpc_host_port" {
  description = "Host port for RPC (container 9944), published on 127.0.0.1 only."
  type        = number
}

variable "postgres_host" {
  description = "Postgres hostname; must match the server certificate's SAN for sslmode=verify-full."
  type        = string
}

variable "postgres_db" {
  description = "db-sync database name."
  type        = string
}

variable "postgres_role" {
  description = "Read-only Postgres role."
  type        = string
}

variable "secrets_dir" {
  description = "Host directory with pgpass and postgres-ca.crt (and keys/ in validator mode); owned by uid 10001, mode 0600/0400."
  type        = string
}

variable "run_as" {
  description = "uid:gid for the node. The image's entrypoint does not drop root, so this is set explicitly."
  type        = string
  default     = "10001:10001"
}

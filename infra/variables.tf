variable "network" {
  description = "Target network. Drives resource names (mn-<network>-*), the Cardano network magic and minimum storage."
  type        = string

  validation {
    condition     = contains(["preview", "preprod", "mainnet"], var.network)
    error_message = "network must be one of preview, preprod, mainnet."
  }
}

variable "docker_host" {
  description = "Docker daemon endpoint. Host-path mounts (secrets, config files) are resolved on this host."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "images" {
  description = "Container images, each pinned as repo:tag@sha256:digest."
  type = object({
    cardano_node       = string
    cardano_db_sync    = string
    postgres           = string
    midnight_node      = string
    indexer_standalone = string
  })

  validation {
    condition     = alltrue([for i in values(var.images) : can(regex("^[^@\\s]+:[^@:\\s]+@sha256:[0-9a-f]{64}$", i)) && !strcontains(i, ":latest@")])
    error_message = "Every image must be pinned as repo:tag@sha256:<64 hex>, and the tag must not be 'latest'."
  }
}

variable "storage_gb" {
  description = "Planned size of each chain-data volume in GB. Docker volumes cannot enforce a size, so this is a validated contract (recorded as a volume label) that maps to disk size on a cloud target."
  type = object({
    cardano_node  = number
    postgres      = number
    dbsync_state  = number
    midnight_node = number
    indexer       = number
  })

  # Minimums per network. PreProd cardano-node 40 GB is from the Midnight cardano-node page
  # ("40 GB NVMe SSD minimum", Preview/Preprod column). The rest are estimates: PreProd
  # postgres from the measured growth on 2026-11-19 (12 GB at ~51% sync), mainnet from typical
  # db-sync deployments. Confirm before production.
  validation {
    condition = alltrue([
      for k, min in {
        preview = { cardano_node = 30, postgres = 40, dbsync_state = 5, midnight_node = 30, indexer = 10 }
        preprod = { cardano_node = 40, postgres = 80, dbsync_state = 10, midnight_node = 50, indexer = 20 }
        mainnet = { cardano_node = 300, postgres = 600, dbsync_state = 30, midnight_node = 100, indexer = 50 }
      }[var.network] : var.storage_gb[k] >= min
    ])
    error_message = "storage_gb is below the minimum for this network (see the table in variables.tf / README)."
  }
}

variable "secrets_dir" {
  description = "Absolute path ON THE DOCKER HOST of the materialised secrets (tmpfs in production). Layout and required file owners: README 'Secrets'."
  type        = string

  validation {
    condition     = startswith(var.secrets_dir, "/") && !strcontains(var.secrets_dir, "..")
    error_message = "secrets_dir must be an absolute path without '..'."
  }
}

variable "cardano_security_parameter" {
  description = "Cardano security parameter k passed to midnight-node (CARDANO_SECURITY_PARAMETER)."
  type        = number
}

variable "midnight_cfg_preset" {
  description = "midnight-node CFG_PRESET (network preset shipped in the image)."
  type        = string
}

variable "midnight_chain_spec" {
  description = "Path of the raw chain spec inside the midnight-node image."
  type        = string
}

variable "midnight_node_name" {
  description = "Telemetry/peer name of the Midnight node."
  type        = string
}

variable "midnight_extra_args" {
  description = "Extra midnight-node CLI arguments (docs for PreProd: --pool-limit 35 --no-private-ip)."
  type        = list(string)
  default     = []
}

variable "midnight_bootnodes" {
  description = "Optional bootnode multiaddrs for midnight-node."
  type        = list(string)
  default     = []
}

variable "validator_keys_enabled" {
  description = "Mount session-key seed files from <secrets_dir>/midnight/keys (validator/FNO mode). Off for a non-authoring node."
  type        = bool
  default     = false
}

variable "indexer_network_id" {
  description = "Indexer APP__APPLICATION__NETWORK_ID (defaults to 'undeployed' in the image, so it must be set)."
  type        = string
}

variable "postgres_tuning" {
  description = "PostgreSQL -c settings (same flags as the live compose stack on PreProd)."
  type        = map(string)
}

variable "ports" {
  description = "Host ports. P2P ports are published on 0.0.0.0; RPC and the indexer API on 127.0.0.1 only."
  type = object({
    cardano_p2p  = number
    midnight_p2p = number
    midnight_rpc = number
    indexer_api  = number
  })
  default = {
    cardano_p2p  = 3001
    midnight_p2p = 30333
    midnight_rpc = 9944
    indexer_api  = 8088
  }

  validation {
    condition     = alltrue([for p in values(var.ports) : p >= 1024 && p <= 65535])
    error_message = "Host ports must be unprivileged (1024-65535)."
  }
}

variable "dbsync_allow_egress" {
  description = "Give cardano-db-sync internet egress (needed only for off-chain pool metadata fetching). Off by default."
  type        = bool
  default     = false
}

# ---- Two-phase start (README "Start-up order") ------------------------------------------------

variable "midnight_start" {
  description = "Phase 2 switch. false: midnight-node and the indexer are created but not started. Set true only after DB Sync is READY."
  type        = bool
  default     = false
}

variable "dbsync_ready_at" {
  description = "UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) of the 'RESULT: READY' line from the DB Sync readiness check against THIS stack (see output dbsync_readiness_check). Required when midnight_start = true."
  type        = string
  default     = ""

  validation {
    condition     = !var.midnight_start || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.dbsync_ready_at))
    error_message = "midnight_start = true requires dbsync_ready_at: run the dbsync_readiness_check output command against this stack until it prints 'RESULT: READY', then set dbsync_ready_at to that run's UTC timestamp."
  }
}

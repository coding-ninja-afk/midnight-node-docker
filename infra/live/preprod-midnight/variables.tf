variable "docker_host" {
  description = "Docker daemon endpoint (the host running the synced Cardano stack)."
  type        = string
  default     = "unix:///var/run/docker.sock"
}

variable "images" {
  description = "Images pinned as repo:tag@sha256:digest (same pins as infra/envs/preprod.tfvars)."
  type = object({
    postgres           = string
    midnight_node      = string
    indexer_standalone = string
  })

  validation {
    condition     = alltrue([for i in values(var.images) : can(regex("^[^@\\s]+:[^@:\\s]+@sha256:[0-9a-f]{64}$", i)) && !strcontains(i, ":latest@")])
    error_message = "Every image must be pinned as repo:tag@sha256:<64 hex>, and the tag must not be 'latest'."
  }
}

variable "stack_network" {
  description = "Existing Docker network of the synced Cardano stack (Postgres is 'postgres' there)."
  type        = string
  default     = "midnight-preprod_default"
}

variable "postgres_host" {
  description = "Postgres host name on stack_network; must match the server certificate's SAN."
  type        = string
  default     = "postgres"
}

variable "dbsync_owner_secrets_dir" {
  description = "Absolute host path with postgres_db, postgres_user, postgres_password of the db-sync table owner (used only by the one-shot index pre-creation)."
  type        = string
}

variable "midnight_secrets_dir" {
  description = "Absolute host path with pgpass and postgres-ca.crt for midnight-node (owner uid 10001)."
  type        = string
}

variable "indexer_secrets_dir" {
  description = "Absolute host path with secret and blockfrost_id for the indexer (owner uid 10001)."
  type        = string
}

variable "storage_gb" {
  description = "Planned sizes (labels on Docker volumes)."
  type = object({
    midnight_node = number
    indexer       = number
  })
  default = { midnight_node = 50, indexer = 20 }
}

variable "ports" {
  description = "Host ports: P2P on 0.0.0.0, RPC and the indexer API on 127.0.0.1."
  type = object({
    midnight_p2p = number
    midnight_rpc = number
    indexer_api  = number
  })
  default = { midnight_p2p = 30333, midnight_rpc = 9944, indexer_api = 8088 }
}

variable "midnight_start" {
  description = "Phase 2 switch: pre-create the indexes, then start midnight-node and the indexer."
  type        = bool
  default     = false
}

variable "dbsync_ready_at" {
  description = "UTC timestamp of the 'RESULT: READY' line from the readiness check against the db-sync this node reads (output dbsync_readiness_check). Required when midnight_start = true."
  type        = string
  default     = ""

  validation {
    condition     = !var.midnight_start || can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", var.dbsync_ready_at))
    error_message = "midnight_start = true requires dbsync_ready_at: run the dbsync_readiness_check output command until it prints 'RESULT: READY', then set dbsync_ready_at to that run's UTC timestamp."
  }
}

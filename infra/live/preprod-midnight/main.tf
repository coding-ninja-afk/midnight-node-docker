# Midnight-only deployment on the host that already runs the synced Cardano stack
# (compose-partner-chains.yml). Reuses the tested modules; the Cardano node, Postgres and db-sync are
# NOT managed here: they are the stack the DB Sync readiness evidence was taken on.
#
#   cardano-node -> postgres/db-sync (compose, synced)
#        -> [gate: dbsync_ready_at] -> index pre-creation (one-shot) -> midnight-node -> indexer
locals {
  common = {
    prefix = "mn-preprod"
    labels = {
      "managed-by" = "terraform"
      "mn.network" = "preprod"
      "mn.stack"   = "mn-preprod-midnight"
      "mn.root"    = "infra/live/preprod-midnight"
    }
    log_opts = { "max-size" = "50m", "max-file" = "5" }
  }
}

# Creates mn-preprod-{internal,p2p,edge}. Midnight reaches Postgres over the existing stack network
# instead, so the module's internal network stays unused here (kept for module reuse).
module "network" {
  source = "../../modules/network"
  common = local.common
}

module "midnight_db_indexes" {
  source = "../../modules/midnight-db-indexes"
  count  = var.midnight_start ? 1 : 0

  common           = local.common
  image            = var.images.postgres
  internal_network = var.stack_network
  postgres_host    = var.postgres_host
  secrets_dir      = var.dbsync_owner_secrets_dir
}

module "midnight_node" {
  source = "../../modules/midnight-node"

  common                     = local.common
  image                      = var.images.midnight_node
  storage_gb                 = var.storage_gb.midnight_node
  start                      = var.midnight_start
  gate_evidence              = var.dbsync_ready_at
  cfg_preset                 = "preprod"
  chain_spec                 = "/res/preprod/chain-spec-raw.json"
  cardano_security_parameter = 2160
  node_name                  = "mn-preprod-fno"
  extra_args                 = ["--pool-limit", "35", "--no-private-ip"]
  p2p_network                = module.network.p2p
  internal_network           = var.stack_network
  p2p_host_port              = var.ports.midnight_p2p
  rpc_host_port              = var.ports.midnight_rpc
  postgres_host              = var.postgres_host
  postgres_db                = "cexplorer"
  postgres_role              = "midnight"
  secrets_dir                = var.midnight_secrets_dir

  depends_on = [module.midnight_db_indexes]
}

module "midnight_indexer" {
  source = "../../modules/midnight-indexer"

  common           = local.common
  image            = var.images.indexer_standalone
  storage_gb       = var.storage_gb.indexer
  start            = var.midnight_start
  network_id       = "preprod"
  node_ws_url      = module.midnight_node.ws_url
  internal_network = var.stack_network
  edge_network     = module.network.edge
  api_host_port    = var.ports.indexer_api
  secrets_dir      = var.indexer_secrets_dir

  depends_on = [module.midnight_node]
}

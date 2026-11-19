# Start-up order (README "Start-up order"):
#   network -> cardano-node -> postgres -> cardano-db-sync -> [gate] -> midnight indexes (one-shot)
#   -> midnight-node -> indexer
# Terraform orders creation and waits for health where waiting is short. The hours-long DB Sync
# catch-up is gated by var.midnight_start + var.dbsync_ready_at, not by a Terraform wait.

module "network" {
  source = "./modules/network"
  common = local.common
}

module "cardano_node" {
  source = "./modules/cardano-node"

  common        = local.common
  image         = var.images.cardano_node
  network       = var.network
  storage_gb    = var.storage_gb.cardano_node
  p2p_network   = module.network.p2p
  p2p_host_port = var.ports.cardano_p2p
}

module "postgres" {
  source = "./modules/postgres"

  common           = local.common
  image            = var.images.postgres
  storage_gb       = var.storage_gb.postgres
  internal_network = module.network.internal
  secrets_dir      = "${var.secrets_dir}/postgres"
  tuning           = var.postgres_tuning
}

module "cardano_db_sync" {
  source = "./modules/cardano-db-sync"

  common           = local.common
  image            = var.images.cardano_db_sync
  network          = var.network
  storage_gb       = var.storage_gb.dbsync_state
  internal_network = module.network.internal
  egress_network   = var.dbsync_allow_egress ? module.network.p2p : null
  ipc_volume       = module.cardano_node.ipc_volume
  postgres_host    = module.postgres.host
  secrets_dir      = "${var.secrets_dir}/postgres"

  depends_on = [module.cardano_node, module.postgres]
}

# Phase 2 only: the db-sync schema exists once DB Sync is READY.
module "midnight_db_indexes" {
  source = "./modules/midnight-db-indexes"
  count  = var.midnight_start ? 1 : 0

  common           = local.common
  image            = var.images.postgres
  internal_network = module.network.internal
  postgres_host    = module.postgres.host
  secrets_dir      = "${var.secrets_dir}/postgres"

  depends_on = [module.cardano_db_sync]
}

module "midnight_node" {
  source = "./modules/midnight-node"

  common                     = local.common
  image                      = var.images.midnight_node
  storage_gb                 = var.storage_gb.midnight_node
  start                      = var.midnight_start
  gate_evidence              = var.dbsync_ready_at
  cfg_preset                 = var.midnight_cfg_preset
  chain_spec                 = var.midnight_chain_spec
  cardano_security_parameter = var.cardano_security_parameter
  node_name                  = var.midnight_node_name
  bootnodes                  = var.midnight_bootnodes
  extra_args                 = var.midnight_extra_args
  validator_keys_enabled     = var.validator_keys_enabled
  p2p_network                = module.network.p2p
  internal_network           = module.network.internal
  p2p_host_port              = var.ports.midnight_p2p
  rpc_host_port              = var.ports.midnight_rpc
  postgres_host              = module.postgres.host
  postgres_db                = module.postgres.dbsync_database
  postgres_role              = module.postgres.midnight_role
  secrets_dir                = "${var.secrets_dir}/midnight"

  # Created after db-sync; *started* only in phase 2 (var.midnight_start), after the index
  # pre-creation (module.midnight_db_indexes) has completed successfully.
  depends_on = [module.cardano_db_sync, module.midnight_db_indexes]
}

module "midnight_indexer" {
  source = "./modules/midnight-indexer"

  common           = local.common
  image            = var.images.indexer_standalone
  storage_gb       = var.storage_gb.indexer
  start            = var.midnight_start
  network_id       = var.indexer_network_id
  node_ws_url      = module.midnight_node.ws_url
  internal_network = module.network.internal
  edge_network     = module.network.edge
  api_host_port    = var.ports.indexer_api
  secrets_dir      = "${var.secrets_dir}/indexer"

  # midnight-node is created with wait = true when started, so Terraform does not create the
  # indexer until the node's RPC healthcheck passes.
  depends_on = [module.midnight_node]
}

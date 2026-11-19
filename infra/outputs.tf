output "stack_prefix" {
  description = "Prefix of every container, volume and network in this stack."
  value       = local.prefix
}

output "dbsync_readiness_check" {
  description = "Phase-1 gate: run from the repo root until it prints RESULT: READY, then set dbsync_ready_at."
  value       = "scripts/dbsync-status.sh --stack tf:${local.prefix} --network ${var.network} --advance 300"
}

output "midnight_readiness_check" {
  description = "Phase-2 check: run from the repo root on the Docker host (RPC is bound to 127.0.0.1)."
  value       = "MIDNIGHT_RPC_URL=http://127.0.0.1:${var.ports.midnight_rpc} scripts/midnight-height-check.sh -n 3 -i 60"
}

output "endpoints" {
  description = "Host endpoints. Only the P2P ports are reachable from other hosts."
  value = {
    cardano_p2p  = "0.0.0.0:${var.ports.cardano_p2p}"
    midnight_p2p = "0.0.0.0:${var.ports.midnight_p2p}"
    midnight_rpc = "127.0.0.1:${var.ports.midnight_rpc}"
    indexer_api  = "http://127.0.0.1:${var.ports.indexer_api}"
  }
}

output "container_specs" {
  description = "Plan-time view of each container's exposure, env names, mounts and start state. Contains no secret values; used by tests/."
  value = {
    cardano_node     = module.cardano_node.spec
    postgres         = module.postgres.spec
    cardano_db_sync  = module.cardano_db_sync.spec
    midnight_node    = module.midnight_node.spec
    midnight_init    = module.midnight_node.init_spec
    midnight_indexer = module.midnight_indexer.spec
  }
}

output "midnight_indexes_spec" {
  description = "Plan-time view of the phase-2 index pre-creation container (null in phase 1)."
  value       = one(module.midnight_db_indexes[*].spec)
}

output "networks" {
  description = "Network names and whether each is internal (no egress)."
  value       = module.network.spec
}

output "volumes" {
  description = "Chain-data volume names and planned sizes."
  value = merge(
    module.cardano_node.volumes,
    module.postgres.volumes,
    module.cardano_db_sync.volumes,
    module.midnight_node.volumes,
    module.midnight_indexer.volumes,
  )
}

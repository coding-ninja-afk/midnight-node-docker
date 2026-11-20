output "dbsync_readiness_check" {
  description = "Readiness check against the db-sync this Midnight node reads (the compose stack)."
  value       = "scripts/dbsync-status.sh --stack compose --network preprod --advance 300"
}

output "midnight_readiness_check" {
  description = "Run from the repo root on the Docker host (RPC is bound to 127.0.0.1)."
  value       = "MIDNIGHT_RPC_URL=http://127.0.0.1:${var.ports.midnight_rpc} scripts/midnight-height-check.sh -n 3 -i 60"
}

output "endpoints" {
  description = "Host endpoints; only P2P is reachable from other hosts."
  value = {
    midnight_p2p = "0.0.0.0:${var.ports.midnight_p2p}"
    midnight_rpc = "127.0.0.1:${var.ports.midnight_rpc}"
    indexer_api  = "http://127.0.0.1:${var.ports.indexer_api}"
  }
}

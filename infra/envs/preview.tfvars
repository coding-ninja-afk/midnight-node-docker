network     = "preview"
secrets_dir = "/run/mn-preview-secrets"

images = {
  # cardano-node / db-sync / postgres: the exact digests the live PreProd compose stack runs.
  cardano_node    = "ghcr.io/intersectmbo/cardano-node:11.0.1@sha256:007da778998d0bdb043fb834c62b9da1c95e33610f31f6f9cccab29a945e2b99"
  cardano_db_sync = "ghcr.io/intersectmbo/cardano-db-sync:13.7.1.0@sha256:b84a0b8b281fa36da1f137668d2079d5758718ae8c1f36ebf5d11063ad915af9"
  postgres        = "postgres:17.12-bookworm@sha256:40865bc877a289da75963d97d72b59633f639fc5af7a4e856bfa3714cae5b536"
  # Midnight: index digests from Docker Hub on 2026-11-19 (node 2.1.101 / indexer 4.4.101 per the support matrix).
  midnight_node      = "midnightntwrk/midnight-node:2.1.101@sha256:0c1ad548d523c1109aa1f16daab1bf72dcb78c7e17b8a8c6d97424ad0eba7b8a"
  indexer_standalone = "midnightntwrk/indexer-standalone:4.4.101@sha256:119f35db548ba1c390845f215bb1e928e73038bef7c315825aee0461bd54499d"
}

storage_gb = {
  cardano_node  = 40
  postgres      = 60
  dbsync_state  = 5
  midnight_node = 30
  indexer       = 10
}

postgres_tuning = {
  shared_buffers       = "1GB"
  effective_cache_size = "4GB"
  maintenance_work_mem = "512MB"
  max_wal_size         = "2GB"
}

# TO CONFIRM: 432 is Cardano Preview's k (and the upstream repo's testnet preset value).
cardano_security_parameter = 432
midnight_cfg_preset        = "preview"
midnight_chain_spec        = "/res/preview/chain-spec-raw.json"
midnight_node_name         = "mn-preview-fno"
midnight_extra_args        = ["--pool-limit", "35", "--no-private-ip"]
# The docs give Preview bootnodes in the full-node guide; add them here before deploying.
midnight_bootnodes = []
indexer_network_id = "preview" # TO CONFIRM

# Input contracts that catch real mistakes before anything is planned.
mock_provider "docker" {}

run "chain_storage_below_minimum_is_rejected" {
  command = plan
  variables {
    storage_gb = {
      cardano_node  = 10
      postgres      = 10
      dbsync_state  = 1
      midnight_node = 10
      indexer       = 1
    }
  }
  expect_failures = [var.storage_gb]
}

run "unpinned_image_is_rejected" {
  command = plan
  variables {
    images = {
      cardano_node       = "ghcr.io/intersectmbo/cardano-node:latest"
      cardano_db_sync    = "ghcr.io/intersectmbo/cardano-db-sync:13.7.1.0"
      postgres           = "postgres:17"
      midnight_node      = "midnightntwrk/midnight-node:2.1.101"
      indexer_standalone = "midnightntwrk/indexer-standalone:4.4.101"
    }
  }
  expect_failures = [var.images]
}

run "unknown_network_is_rejected" {
  command = plan
  variables {
    network = "testnet-02"
  }
  expect_failures = [var.network]
}

run "relative_secrets_dir_is_rejected" {
  command = plan
  variables {
    secrets_dir = "secrets"
  }
  expect_failures = [var.secrets_dir]
}

run "privileged_host_port_is_rejected" {
  command = plan
  variables {
    ports = {
      cardano_p2p  = 3001
      midnight_p2p = 30333
      midnight_rpc = 443
      indexer_api  = 8088
    }
  }
  expect_failures = [var.ports]
}

run "volumes_record_planned_size" {
  command = plan

  assert {
    condition     = output.volumes.postgres.storage_gb >= 40 && output.volumes.cardano_node.storage_gb >= 30
    error_message = "Chain-data volumes must carry their planned size."
  }
}

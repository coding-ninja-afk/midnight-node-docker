# Two-phase start: midnight-node and the indexer only start after DB Sync is READY on THIS stack.
mock_provider "docker" {}

run "phase1_creates_but_does_not_start_midnight" {
  command = plan

  assert {
    condition     = output.container_specs.midnight_node.start == false && output.container_specs.midnight_node.must_run == false
    error_message = "Phase 1: midnight-node must be created but not started."
  }
  assert {
    condition     = output.container_specs.midnight_indexer.start == false
    error_message = "Phase 1: the indexer must not start before midnight-node."
  }
  assert {
    condition     = output.midnight_indexes_spec == null
    error_message = "Phase 1: no index pre-creation (the db-sync schema may not exist yet)."
  }
}

run "readiness_check_targets_this_terraform_stack" {
  command = plan

  assert {
    condition     = output.dbsync_readiness_check == "scripts/dbsync-status.sh --stack tf:mn-${var.network} --network ${var.network} --advance 300"
    error_message = "The DB Sync gate must check this stack's containers (tf:mn-<network>), not the compose stack."
  }
  assert {
    condition     = strcontains(output.midnight_readiness_check, "MIDNIGHT_RPC_URL=http://127.0.0.1:${var.ports.midnight_rpc}")
    error_message = "The Midnight check must target this stack's RPC port."
  }
}

run "phase2_without_evidence_is_rejected" {
  command = plan
  variables {
    midnight_start = true
  }
  expect_failures = [var.dbsync_ready_at]
}

run "phase2_with_malformed_timestamp_is_rejected" {
  command = plan
  variables {
    midnight_start  = true
    dbsync_ready_at = "2026-11-20 08:00" # not UTC ISO-8601 with Z
  }
  expect_failures = [var.dbsync_ready_at]
}

run "phase2_starts_node_then_indexer" {
  command = plan
  variables {
    midnight_start  = true
    dbsync_ready_at = "2026-11-20T08:00:00Z"
  }

  assert {
    condition     = output.container_specs.midnight_node.start && output.container_specs.midnight_node.must_run
    error_message = "Phase 2: midnight-node must start."
  }
  # wait = true + a healthcheck makes Terraform hold the indexer (which depends_on the node
  # module) until the node's RPC answers. Ordering itself is checked by scripts/check-order.sh.
  assert {
    condition     = output.container_specs.midnight_node.wait && output.container_specs.midnight_node.has_health
    error_message = "Phase 2: Terraform must wait for midnight-node's healthcheck before creating the indexer."
  }
  assert {
    condition     = output.container_specs.midnight_indexer.start
    error_message = "Phase 2: the indexer must start."
  }
  assert {
    condition     = contains(output.container_specs.midnight_indexer.env, "APP__INFRA__NODE__URL=ws://midnight-node:9944")
    error_message = "The indexer must follow this stack's midnight-node."
  }
}

run "phase2_pre_creates_indexes_safely" {
  command = plan
  variables {
    midnight_start  = true
    dbsync_ready_at = "2026-11-20T08:00:00Z"
  }

  assert {
    condition     = output.midnight_indexes_spec != null
    error_message = "Phase 2 must pre-create midnight-node's indexes (its runtime role is read-only)."
  }
  assert {
    condition     = output.midnight_indexes_spec.attach && !output.midnight_indexes_spec.must_run
    error_message = "The index container must run to completion during apply (attach = true, must_run = false)."
  }
  assert {
    condition     = length(output.midnight_indexes_spec.ports) == 0 && output.midnight_indexes_spec.networks == [output.networks.internal.name]
    error_message = "The index container must publish nothing and use the internal network only."
  }
  assert {
    condition     = alltrue([for m in output.midnight_indexes_spec.host_mounts : m.read_only]) && output.midnight_indexes_spec.uploads == 0
    error_message = "The index container must mount secrets read-only and never use upload blocks."
  }
  assert {
    condition     = alltrue([for e in output.midnight_indexes_spec.env : endswith(split("=", e)[0], "_FILE") if can(regex("(?i)password", split("=", e)[0]))])
    error_message = "The db-sync owner password must reach the index container as a *_FILE path."
  }
  # The runtime role is unchanged: still the read-only 'midnight' user.
  assert {
    condition     = anytrue([for e in output.container_specs.midnight_node.env : startswith(e, "DB_SYNC_POSTGRES_CONNECTION_STRING=postgres://midnight@")])
    error_message = "midnight-node must keep connecting as the read-only 'midnight' role."
  }
}

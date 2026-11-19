output "ws_url" {
  description = "RPC websocket URL on the internal network, for the indexer."
  value       = "ws://midnight-node:9944"
}

output "volumes" {
  description = "Chain-data volume name and planned size."
  value       = { midnight_node = { name = docker_volume.data.name, storage_gb = var.storage_gb } }
}

output "spec" {
  description = "Plan-time view of the node container for tests (no secret values)."
  value = {
    name          = docker_container.this.name
    image         = var.image
    user          = docker_container.this.user
    start         = docker_container.this.start
    must_run      = docker_container.this.must_run
    wait          = docker_container.this.wait
    has_health    = length(docker_container.this.healthcheck) > 0
    ports         = [for p in docker_container.this.ports : { internal = p.internal, external = p.external, ip = p.ip }]
    networks      = [for n in docker_container.this.networks_advanced : n.name]
    env           = docker_container.this.env
    command       = docker_container.this.command
    host_mounts   = [for v in docker_container.this.volumes : { host_path = v.host_path, container_path = v.container_path, read_only = v.read_only } if v.host_path != null && v.host_path != ""]
    uploads       = length(docker_container.this.upload)
    cap_drop      = flatten([for c in docker_container.this.capabilities : c.drop])
    security_opts = docker_container.this.security_opts
  }
}

output "init_spec" {
  description = "Plan-time view of the one-shot volume-ownership container."
  value = {
    name         = docker_container.volume_init.name
    must_run     = docker_container.volume_init.must_run
    attach       = docker_container.volume_init.attach
    network_mode = docker_container.volume_init.network_mode
    ports        = [for p in docker_container.volume_init.ports : { internal = p.internal, external = p.external, ip = p.ip }]
    host_mounts  = []
    env          = docker_container.volume_init.env
    uploads      = length(docker_container.volume_init.upload)
  }
}

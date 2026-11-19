output "ipc_volume" {
  description = "Volume holding node.socket, for cardano-db-sync."
  value       = docker_volume.ipc.name
}

output "volumes" {
  description = "Data volume name and planned size."
  value       = { cardano_node = { name = docker_volume.data.name, storage_gb = var.storage_gb } }
}

output "spec" {
  description = "Plan-time view of the container for tests (no secret values)."
  value = {
    name        = docker_container.this.name
    image       = var.image
    start       = docker_container.this.start
    ports       = [for p in docker_container.this.ports : { internal = p.internal, external = p.external, ip = p.ip }]
    networks    = [for n in docker_container.this.networks_advanced : n.name]
    env         = docker_container.this.env
    host_mounts = [for v in docker_container.this.volumes : { host_path = v.host_path, container_path = v.container_path, read_only = v.read_only } if v.host_path != null && v.host_path != ""]
    uploads     = length(docker_container.this.upload)
  }
}

output "host" {
  description = "Hostname of Postgres on the internal network."
  value       = "postgres"
}

output "dbsync_database" {
  description = "Database db-sync writes to (read from secrets at runtime; this is the expected name)."
  value       = "cexplorer"
}

output "midnight_role" {
  description = "Read-only role created by files/10-midnight-role.sh."
  value       = "midnight"
}

output "volumes" {
  description = "Data volume name and planned size."
  value       = { postgres = { name = docker_volume.data.name, storage_gb = var.storage_gb } }
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
    command     = docker_container.this.command
  }
}


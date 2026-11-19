output "internal" {
  description = "Name of the internal (no egress) network."
  value       = docker_network.internal.name
}

output "p2p" {
  description = "Name of the P2P network (egress, published P2P ports)."
  value       = docker_network.p2p.name
}

output "edge" {
  description = "Name of the edge network (loopback-published APIs, no outbound NAT)."
  value       = docker_network.edge.name
}

output "spec" {
  description = "Network names with their isolation flags, for tests."
  value = {
    internal = { name = docker_network.internal.name, internal = docker_network.internal.internal, options = docker_network.internal.options }
    p2p      = { name = docker_network.p2p.name, internal = docker_network.p2p.internal, options = docker_network.p2p.options }
    edge     = { name = docker_network.edge.name, internal = docker_network.edge.internal, options = docker_network.edge.options }
  }
}

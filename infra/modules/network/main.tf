# internal: chain traffic between containers. internal = true means no route to the internet
#           and no published ports, so nothing on it is reachable from outside the host.
resource "docker_network" "internal" {
  name     = "${var.common.prefix}-internal"
  driver   = "bridge"
  internal = true

  dynamic "labels" {
    for_each = var.common.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# p2p: egress + published P2P ports for cardano-node and midnight-node.
resource "docker_network" "p2p" {
  name   = "${var.common.prefix}-p2p"
  driver = "bridge"

  dynamic "labels" {
    for_each = var.common.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# edge: lets the indexer publish its API on 127.0.0.1 without giving it internet egress
# (published ports need a non-internal network; masquerade off = no outbound NAT).
resource "docker_network" "edge" {
  name   = "${var.common.prefix}-edge"
  driver = "bridge"
  options = {
    "com.docker.network.bridge.enable_ip_masquerade" = "false"
  }

  dynamic "labels" {
    for_each = var.common.labels
    content {
      label = labels.key
      value = labels.value
    }
  }
}

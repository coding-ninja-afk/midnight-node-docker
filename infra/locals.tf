locals {
  prefix = "mn-${var.network}"

  # Shared container settings, mirroring the live compose stack.
  common = {
    prefix = local.prefix
    labels = {
      "managed-by"  = "terraform"
      "mn.network"  = var.network
      "mn.stack"    = local.prefix
      "mn.repo-dir" = "infra"
    }
    log_opts = {
      "max-size" = "50m"
      "max-file" = "5"
    }
  }
}

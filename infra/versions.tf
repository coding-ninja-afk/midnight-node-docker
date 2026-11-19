terraform {
  # Exact minor line: plan/test behaviour (mock providers, cross-variable validation) is pinned.
  required_version = "~> 1.17.0"

  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      # Exact pin; checksums in .terraform.lock.hcl. 4.7.0 chosen after the compatibility run
      # against 4.6.0 described in README.md ("Provider version").
      version = "4.7.0"
    }
  }
}

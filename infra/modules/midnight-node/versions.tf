terraform {
  required_version = ">= 1.9.0"

  required_providers {
    docker = {
      source = "kreuzwerker/docker"
      # Range, not a pin: the root module pins the exact version. Tested on 4.6.0 and 4.7.0.
      version = ">= 4.6.0, < 5.0.0"
    }
  }
}

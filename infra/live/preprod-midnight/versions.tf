terraform {
  required_version = "~> 1.17.0"

  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.7.0"
    }
  }

  # Local state on the Docker host until the S3 bucket exists (see infra/backend.tf). It holds no
  # secret values (secrets are host paths); *.tfstate is git-ignored.
  backend "local" {}
}

provider "docker" {
  host = var.docker_host
}

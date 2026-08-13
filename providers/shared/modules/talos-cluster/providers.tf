terraform {
  required_version = ">= 1.6.2, < 2.0.0"

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

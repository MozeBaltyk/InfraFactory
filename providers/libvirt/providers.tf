terraform {
  required_version = ">= 1.6.2, < 2.0.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11.0"
    }
  }
}

provider "libvirt" {
  uri = local.libvirt_uri
}

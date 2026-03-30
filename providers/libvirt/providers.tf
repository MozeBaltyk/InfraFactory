terraform {
  required_version = "= 1.6.2"

  required_providers {
    libvirt = {
      source  = "multani/libvirt"
      version = "0.6.3-1+4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "libvirt" {
  uri = local.libvirt_uri
}

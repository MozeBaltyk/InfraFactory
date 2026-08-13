terraform {
  required_version = ">= 1.6.2, < 2.0.0"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.18.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3.0"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14.0"
    }
  }
}

provider "ovh" {
  endpoint           = var.ovh_endpoint
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}

provider "openstack" {
  # Authentication is read non-interactively from OS_* or clouds.yaml/OS_CLOUD.
  region = var.cluster.region
}

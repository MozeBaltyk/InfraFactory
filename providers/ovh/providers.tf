terraform {
  #required_version = "= 1.6.2"

  required_providers {
    ovh = {
      source = "ovh/ovh"
    }
    local = {
      source = "hashicorp/local"
    }
    null = {
      source = "hashicorp/null"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source = "hashicorp/tls"
    }
    openstack = {
      source = "terraform-provider-openstack/openstack"
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
  # Talos image upload uses OpenStack auth from var.openstack or OS_* env/OpenRC.
  # ponytail: dummy config keeps non-Talos OVH plans from requiring OpenStack auth.
  cloud                         = var.cluster.cloud_init_selected == "talos" ? var.openstack.cloud : null
  auth_url                      = var.cluster.cloud_init_selected == "talos" ? var.openstack.auth_url : "http://127.0.0.1/identity"
  user_name                     = var.cluster.cloud_init_selected == "talos" ? var.openstack.user_name : "unused"
  password                      = var.cluster.cloud_init_selected == "talos" ? var.openstack.password : "unused"
  tenant_name                   = var.cluster.cloud_init_selected == "talos" ? var.openstack.tenant_name : "unused"
  tenant_id                     = var.cluster.cloud_init_selected == "talos" ? var.openstack.tenant_id : null
  user_domain_name              = var.cluster.cloud_init_selected == "talos" ? var.openstack.user_domain_name : null
  project_domain_name           = var.cluster.cloud_init_selected == "talos" ? var.openstack.project_domain_name : null
  application_credential_id     = var.cluster.cloud_init_selected == "talos" ? var.openstack.application_credential_id : null
  application_credential_name   = var.cluster.cloud_init_selected == "talos" ? var.openstack.application_credential_name : null
  application_credential_secret = var.cluster.cloud_init_selected == "talos" ? var.openstack.application_credential_secret : null
  region                        = coalesce(var.openstack.region, var.cluster.region)
}

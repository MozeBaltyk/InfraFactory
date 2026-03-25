##
## Azure credentials
##
variable "azure_subscription_id" {
  description = "Azure Subscription ID"
}

variable "azure_client_id" {
  description = "Azure Client ID"
}

variable "azure_client_secret" {
  description = "Azure Client Secret"
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
}

# Version Mapping
variable "os_catalog" {
  description = "OS image catalog"
  type = map(object({
    os_name            = string
    hostname_prefix    = string
    image = object({
      publisher = string
      offer     = string
      sku       = string
      version   = string
    })
    default_instance_size = string
  }))

  default = {
    ubuntu24 = {
      os_name         = "ubuntu"
      hostname_prefix = "slaz"
      image = {
        publisher = "Canonical"
        offer     = "ubuntu-24_04-lts"
        sku       = "server"
        version   = "latest"
      }
      default_instance_size = "Standard_B2s"
    }

    ubuntu22 = {
      os_name         = "ubuntu"
      hostname_prefix = "slaz"
      image = {
        publisher = "Canonical"
        offer     = "0001-com-ubuntu-server-jammy"
        sku       = "22_04-lts-gen2"
        version   = "latest"
      }
      default_instance_size = "Standard_B2s"
    }
  }
}

variable "os" {
  description = "OS selection"

  type = object({
    selected = string
  })

  default = {
    selected = "ubuntu24"
  }
}

###################################
# Cluster topology
###################################
variable "cluster" {
  description = "Cluster topology"

  type = object({
    id        = string
    domain    = string
    masters   = number
    workers   = number
    timezone  = string
    region    = string
    username  = string
    cloud_init_selected = string
  })

  default = {
    id       = "factory"
    domain   = "lab"
    masters  = 1
    workers  = 0
    timezone = "Europe/Paris"
    region = "westeurope"
    username = "localadmin"
    cloud_init_selected = "k3s"
  }
}

###################################
# VMs infra
###################################
variable "infra" {
  description = "VM infrastructure configuration"

  type = object({
    disk_size = number
    instance_size = string
  })

  default = {
    instance_size = "standard_d8s_v5"
    disk_size = 10  #GB
  }
}

###################################
# Network Config
###################################
variable "network" {
  description = "Libvirt network configuration"

  type = object({
    cidr = string
    ip_type = string
  })

  default = {
    cidr    = "192.168.100.0/24"
    ip_type = "dhcp"
  }
}

###################################
# K3s specific variables
###################################
variable "k3s" {
  description = "K3s cluster configuration"

  type = object({
    version          = string
    token            = string
    etcd_enabled     = bool
    traefik_enabled  = bool
    servicelb_enabled = bool
    local_storage_enabled = bool
    metrics_server_enabled = bool
  })

  default = {
    version           = "v1.34.5+k3s1"
    token             = "my-super-secret-shared-token-12345"
    etcd_enabled      = true
    traefik_enabled   = true
    servicelb_enabled = true
    local_storage_enabled = true
    metrics_server_enabled = true
  }
}

###################################
# Ansible Pull specific variables
###################################
variable "ansible" {
  type = object({
    pull = optional(object({
      repo          = string
      branch        = string
      playbook      = string
      timer         = optional(string) #in minutes, e.g "30mins", "1h", "2h30m", etc.
    }))
  })
  default = {}
}


# Local Settings
data "http" "my_ip" {
  url = "http://ifconfig.me/ip"
}

locals {
  my_public_ip = "${chomp(trimspace(data.http.my_ip.response_body))}/32"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  network_gateway = cidrhost(var.network.cidr, 1)

  local_env_path = "${path.module}/../../env/AZ/${terraform.workspace}"

  master_details = [
    for i in range(var.cluster.masters) : {
      name = format("${local.os.hostname_prefix}-m%02d", i + 1)
      role = "master"
    }
  ]

  worker_details = [
    for i in range(var.cluster.workers) : {
      name = format("${local.os.hostname_prefix}-w%02d", i + 1)
      role = "worker"
    }
  ]

}

variable "nsg_rules" {
  description = "List of NSG rules with port, name, and allowed source"
  type = map(object({
    port = number
    name = string
    description = string
    source_address = string
  }))

  default = {
    ssh = {
      port           = 22
      name           = "Allow_SSH"
      description    = "SSH access from admin IP"
      source_address = ""
    }
    k8s_api = {
      port           = 6443
      name           = "Allow_K8S_API"
      description    = "Kubernetes API access from admin IP"
      source_address = ""
    }
  }
}
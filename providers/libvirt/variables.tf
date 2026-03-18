# Version Mapping
variable "os_catalog" {
  description = "Available OS images"
  type = map(object({
    os_name            = string
    os_version_short   = number
    os_version_long    = string
    os_URL             = string
  }))
  default = {
    ubuntu24 = {
      os_name            = "ubuntu"
      os_version_short   = 24
      os_version_long    = "24.04"
      os_URL             = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
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
    username  = string
    cloud_init_selected = string
    factory_root_path = string
  })

  default = {
    id       = "factory"
    domain   = "lab"
    masters  = 1
    workers  = 0
    timezone = "Europe/Paris"
    username = "localadmin"
    cloud_init_selected = "k3s"
    factory_root_path = "/srv"
  }
}

###################################
# VMs infra
###################################
variable "infra" {
  description = "VM infrastructure configuration"

  type = object({
    memory_gb = number
    cpu       = number
    disk_size = number
  })

  default = {
    cpu       = 2
    disk_size = 10 #GB
    memory_gb = 4  #GB
  }
}

###################################
# Network Config
###################################
variable "network" {
  description = "Libvirt network configuration"

  type = object({
    cidr        = optional(string)
    ip_type     = string
    mode        = string
    bridge_name = optional(string)
  })

  default = {
    cidr    = "192.168.100.0/24"
    ip_type = "dhcp"
    mode    = "nat"
  }

  # Validate allowed modes and required fields based on mode
  validation {
    condition = (
      (var.network.mode == "nat" || var.network.mode == "route" ? var.network.cidr != null : true) &&
      (var.network.mode == "bridge" ? var.network.bridge_name != null : true)
    )
    error_message = "cidr required for nat/route, bridge_name required for bridge mode."
  }

  # Validate allowed IP types (dhcp or static)
  validation {
    condition = contains(["dhcp", "static"], var.network.ip_type)
    error_message = "ip_type must be either 'dhcp' or 'static'."
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

# Local Settings
locals {
  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  network_gateway = (var.network.mode == "nat" || var.network.mode == "route") ? cidrhost(var.network.cidr, 1) : null

  factory_pool_path = "${var.cluster.factory_root_path}/${var.cluster.id}/pool"

  local_env_path = "${path.module}/../../env/KVM/${terraform.workspace}"

  master_details = [
    for i in range(var.cluster.masters) : {
      name = format("master%02d", i + 1)
      role = "master"
    }
  ]

  worker_details = [
    for i in range(var.cluster.workers) : {
      name = format("worker%02d", i + 1)
      role = "worker"
    }
  ]
}

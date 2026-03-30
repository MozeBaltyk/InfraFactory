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
    timezone  = string
    username  = string
    cloud_init_selected = string
    factory_root_path = string  })

  default = {
    id       = "factory"
    domain   = "lab"
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
    masters = object({
      count         = number
      cpu           = number
      disk_size     = number
      memory_gb     = number
      mac_addresses = optional(list(string), [])
      ip_addresses = optional(list(string), [])
    })

    workers = object({
      count         = number
      cpu           = number
      disk_size     = number
      memory_gb     = number
      mac_addresses = optional(list(string), [])
      ip_addresses = optional(list(string), [])
    })
  })

  default = {
    masters = {
      count         = 1
      cpu           = 2
      disk_size     = 10
      memory_gb     = 4
      mac_addresses = []
      ip_addresses = []
    }

    workers = {
      count         = 0
      cpu           = 2
      disk_size     = 10
      memory_gb     = 4
      mac_addresses = []
      ip_addresses = []
    }
  }

  validation {
    condition = alltrue([
      for mac in concat(var.infra.masters.mac_addresses, var.infra.workers.mac_addresses) :
      can(regex("^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$", mac))
    ])
    error_message = "All MAC addresses must be valid (e.g. 52:54:00:9e:ba:ba)."
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
    gateway     = optional(string)
    extra_dns   = optional(list(string), ["8.8.8.8", "8.8.4.4"])
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

  # If static IP + bridge, ensure that gateway is set.
  validation {
  condition = (
    var.network.mode != "bridge" ||
    var.network.ip_type != "static" ||
    var.network.gateway != null
  )
  error_message = "Bridge mode with static IP requires network.gateway to be set."
  }

}

# libvirt connection details
variable "libvirt" {
  type = object({
    remote = bool
    user   = string
    host   = string
    port   = optional(number, 22)
    system = string
  })

  default = {
    remote = false
    user   = "root"
    host   = "localhost"
    system = "system"
  }
}

# Local Settings
locals {
  libvirt_uri = var.libvirt.remote ? "qemu+ssh://${var.libvirt.user}@${var.libvirt.host}:${var.libvirt.port}/${var.libvirt.system}" : "qemu:///${var.libvirt.system}"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  # For NAT/Route - standard gateway cidr 1; for bridge - user provide gateway (assuming host handles routing)
  network_gateway = ( 
    var.network.mode == "nat" || var.network.mode == "route"
    ) ? cidrhost(var.network.cidr, 1) : (
      var.network.gateway != null
      ? var.network.gateway
      : null
    )

  # For NAT/Route, use Libvirt gateway + extra DNS; For bridge, use extra DNS only (assuming host handles DNS)
  dns_servers = join(",",
    var.network.mode == "bridge"
    ? var.network.extra_dns
    : concat(
        local.network_gateway != null ? [local.network_gateway] : [],
        var.network.extra_dns
      )
  )

  factory_pool_path = "${var.cluster.factory_root_path}/${var.cluster.id}/pool"

  local_env_path = "${path.module}/../../env/KVM/${terraform.workspace}"

  master_details = [
    for i in range(var.infra.masters.count) : {
      name = format("master%02d", i + 1)
      role = "master"
      cpu  = var.infra.masters.cpu
      memory_mb = var.infra.masters.memory_gb * 1024
      disk_size = var.infra.masters.disk_size
      mac = length(var.infra.masters.mac_addresses) > i ? var.infra.masters.mac_addresses[i] : null
      ip = length(var.infra.masters.ip_addresses) > i ? var.infra.masters.ip_addresses[i] : null
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name = format("worker%02d", i + 1)
      role = "worker"
      cpu  = var.infra.workers.cpu
      memory_mb = var.infra.workers.memory_gb * 1024
      disk_size = var.infra.workers.disk_size
      mac = length(var.infra.workers.mac_addresses) > i ? var.infra.workers.mac_addresses[i] : null
      ip = length(var.infra.workers.ip_addresses) > i ? var.infra.workers.ip_addresses[i] : null
    }
  ]
}

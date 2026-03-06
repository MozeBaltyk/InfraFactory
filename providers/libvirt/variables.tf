# Version Selection
variable "selected_version" {
  description = "Selected OS version"
  default     = "ubuntu24" # Can be changed to "fedora41" as needed
}

# Version Mapping
variable "Versionning" {
  type = map(object({
    os_name            = string
    os_version_short   = number
    os_version_long    = string
    os_URL             = string
    cloud_init_version = string
  }))
  default = {
    ubuntu24 = {
      os_name            = "ubuntu"
      os_version_short   = 24
      os_version_long    = "24.04"
      os_URL             = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
      cloud_init_version = "default"
    }
  }
}

variable "pool" {
  description = "Libvirt storage pool name"
  default     = "factory"
}

variable "clusterid" {
  description = "Cluster ID"
  default     = "factory"
}

variable "domain" {
  description = "Domain for the cluster"
  default     = "local"
}

variable "ip_type" {
  description = "Type of IP assignment (e.g., dhcp)"
  default     = "dhcp" # Other valid types are 'static', etc.
}

variable "network_name" {
  description = "Libvirt network name"
  default     = "factory"
}

variable "network_cidr" {
  description = "CIDR for the Libvirt network"
  default     = "192.168.100.0/24"
}

variable "memory_size" {
  description = "Memory for each VM in MB"
  default     = 4096
}

variable "cpu_size" {
  description = "Number of CPUs for each VM"
  default     = 2
}

variable "timezone" {
  description = "Timezone for the VMs"
  default     = "Europe/Paris"
}

variable "masters_number" {
  description = "Number of master nodes"
  default     = 3
}

variable "workers_number" {
  description = "Number of worker nodes"
  default     = 0
}

variable "masters_mac_addresses" {
  description = "List of MAC addresses for master nodes"
  type        = list(string)
  default     = ["52:54:00:36:14:e5", "52:54:00:36:14:e6", "52:54:00:36:14:e7"]
}

variable "workers_mac_addresses" {
  description = "List of MAC addresses for worker nodes"
  type        = list(string)
  default     = ["52:54:00:c8:7a:7a", "52:54:00:90:44:86"]
}

variable "product" {
  description = "Name of the product"
  default     = "factory"
}

variable "release_version" {
  description = "Release version of the product"
  default     = "v1.0"
}

# Local Settings
locals {
  qcow2_image        = lookup(var.Versionning[var.selected_version], "os_URL", "")
  cloud_init_version = lookup(var.Versionning[var.selected_version], "cloud_init_version", "")
  subdomain          = "${var.clusterid}.${var.domain}"
  os_name            = lookup(var.Versionning[var.selected_version], "os_name", "")
  os_version_short   = lookup(var.Versionning[var.selected_version], "os_version_short", "")
  factory_pool_path  = "/srv/${var.pool}/pool"

  master_details = tolist([
    for a in range(var.masters_number) : {
      name = format("master%02d", a + 1)
      mac  = var.masters_mac_addresses[a]
    }
  ])

  worker_details = tolist([
    for b in range(var.workers_number) : {
      name = format("worker%02d", b + 1)
      mac  = var.workers_mac_addresses[b]
    }
  ])
}

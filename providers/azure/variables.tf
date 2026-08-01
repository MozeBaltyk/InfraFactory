##
## Azure credentials
##
variable "infra_provider" {
  default = "AZ"
}

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
    os_name         = string
    hostname_prefix = string
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
    id                      = string
    domain                  = string
    timezone                = string
    region                  = string
    username                = string
    cloud_init_selected     = string
    package_upgrade_enabled = optional(bool, true)
  })

  default = {
    id                      = "factory"
    domain                  = "lab"
    timezone                = "Europe/Paris"
    region                  = "westeurope"
    username                = "localadmin"
    cloud_init_selected     = "k3s"
    package_upgrade_enabled = true
  }
}

###################################
# VMs infra
###################################
variable "infra" {
  description = "VM infrastructure configuration"

  type = object({
    masters = object({
      count             = number
      instance_size     = optional(string, "Standard_D2s_v5")
      disk_size         = optional(number, 40)
      user_data_enabled = optional(bool, true)
      extra_disks = optional(list(object({
        size_gb    = number
        mount_path = string
        filesystem = optional(string, "ext4")
        label      = string
      })), [])
    })

    workers = object({
      count             = number
      instance_size     = optional(string, "Standard_D2s_v5")
      disk_size         = optional(number, 40)
      user_data_enabled = optional(bool, true)
      extra_disks = optional(list(object({
        size_gb    = number
        mount_path = string
        filesystem = optional(string, "ext4")
        label      = string
      })), [])
    })

    vms = optional(object({
      count             = number
      instance_size     = optional(string, "Standard_D2s_v5")
      disk_size         = optional(number, 40)
      user_data_enabled = optional(bool, true)
      extra_disks = optional(list(object({
        size_gb    = number
        mount_path = string
        filesystem = optional(string, "ext4")
        label      = string
      })), [])
    }), { count = 0 })
  })

  default = {
    masters = {
      count = 1
    }
    workers = {
      count = 0
    }
    vms = {
      count = 0
    }
  }

  validation {
    condition     = var.infra.masters.count >= 1 || var.infra.workers.count == 0
    error_message = "Azure workers require at least one master node. Use infra.vms for VM-only deployments."
  }
}

###################################
# Network Config
###################################
variable "network" {
  description = "Azure network configuration"

  type = object({
    cidr         = string
    subnet_index = optional(number, 0)
    ip_type      = string
  })

  default = {
    cidr    = "192.168.100.0/24"
    ip_type = "dhcp"
  }
}

# Local Settings
data "http" "my_ip" {
  url = "http://ifconfig.me/ip"
}

locals {
  env_root = "${path.module}/../../env"
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  my_public_ip = "${chomp(trimspace(data.http.my_ip.response_body))}/32"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  network_gateway = cidrhost(var.network.cidr, 1)

  master_details = [
    for i in range(var.infra.masters.count) : {
      name              = format("${local.os.hostname_prefix}-m%02d", i + 1)
      role              = "master"
      instance_size     = var.infra.masters.instance_size
      disk_size         = var.infra.masters.disk_size
      extra_disks       = try(var.infra.masters.extra_disks, [])
      user_data_enabled = var.infra.masters.user_data_enabled
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name              = format("${local.os.hostname_prefix}-w%02d", i + 1)
      role              = "worker"
      instance_size     = var.infra.workers.instance_size
      disk_size         = var.infra.workers.disk_size
      extra_disks       = try(var.infra.workers.extra_disks, [])
      user_data_enabled = var.infra.workers.user_data_enabled
    }
  ]

  vm_details = [
    for i in range(var.infra.vms.count) : {
      name              = format("${local.os.hostname_prefix}-v%02d", i + 1)
      role              = "vm"
      instance_size     = var.infra.vms.instance_size
      disk_size         = var.infra.vms.disk_size
      extra_disks       = try(var.infra.vms.extra_disks, [])
      user_data_enabled = var.infra.vms.user_data_enabled
    }
  ]

  # Mapping for easier access
  masters_map = {
    for vm in local.master_details : vm.name => vm
  }

  workers_map = {
    for vm in local.worker_details : vm.name => vm
  }

  vms_map = {
    for vm in local.vm_details : vm.name => vm
  }

  all_vms_map = merge(local.masters_map, local.workers_map, local.vms_map)

  # Get the first master
  first_master_name = try(local.master_details[0].name, null)

  # Flattened list of extra disks with VM name and index for easier resource creation
  vm_disks = {
    for vm in concat(local.master_details, local.worker_details, local.vm_details) :
    vm.name => [
      for i, disk in vm.extra_disks : {
        index      = i
        size_gb    = disk.size_gb
        mount_path = disk.mount_path
        filesystem = disk.filesystem
        label      = disk.label
        lun        = i # Azure uses LUN instead of WWN
      }
    ]
  }

  vm_disks_flat = merge([
    for vm_name, disks in local.vm_disks : {
      for i, disk in disks :
      "${vm_name}-${i}" => merge(disk, {
        vm_name = vm_name
        index   = i
      })
    }
  ]...)

}

variable "nsg_rules" {
  description = "List of NSG rules with port, name, and allowed source"
  type = map(object({
    port           = number
    name           = string
    description    = string
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

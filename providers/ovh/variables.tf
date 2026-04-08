##
## OVH credentials
##
variable "infra_provider" {
  default = "OVH"
}

variable "ovh_endpoint" {
  description = "OVH API endpoint"
  type        = string
  default     = "ovh-eu"
}

variable "ovh_application_key" {
  description = "OVH application key"
  type        = string
  sensitive   = true
}

variable "ovh_application_secret" {
  description = "OVH application secret"
  type        = string
  sensitive   = true
}

variable "ovh_consumer_key" {
  description = "OVH consumer key"
  type        = string
  sensitive   = true
}

variable "ovh_project_service_name" {
  description = "OVHcloud Public Cloud project service name"
  type        = string
}

# Version Mapping
variable "os_catalog" {
  description = "OS image catalog"
  type = map(object({
    os_name         = string
    hostname_prefix = string
    image = object({
      name = string
    })
    default_instance_size = string
  }))

  default = {
    ubuntu24 = {
      os_name         = "ubuntu"
      hostname_prefix = "slovh"
      image = {
        name = "Ubuntu 24.04"
      }
      default_instance_size = "b2-7"
    }

    ubuntu22 = {
      os_name         = "ubuntu"
      hostname_prefix = "slovh"
      image = {
        name = "Ubuntu 22.04"
      }
      default_instance_size = "b2-7"
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
    id                  = string
    domain              = string
    timezone            = string
    region              = string
    username            = string
    cloud_init_selected = string
  })

  default = {
    id                  = "factory"
    domain              = "lab"
    timezone            = "Europe/Paris"
    region              = "GRA9"
    username            = "localadmin"
    cloud_init_selected = "k3s"
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
      instance_size = optional(string, "b2-7")
      disk_size     = optional(number, 40)
      extra_disks = optional(list(object({
        size_gb    = number
        mount_path = string
        filesystem = optional(string, "ext4")
        label      = string
      })), [])
    })

    workers = object({
      count         = number
      instance_size = optional(string, "b2-7")
      disk_size     = optional(number, 40)
      extra_disks = optional(list(object({
        size_gb    = number
        mount_path = string
        filesystem = optional(string, "ext4")
        label      = string
      })), [])
    })
  })

  default = {
    masters = {
      count = 1
    }
    workers = {
      count = 0
    }
  }

  validation {
    condition     = var.infra.masters.count >= 1
    error_message = "OVH requires at least one master node."
  }

  validation {
    condition     = length(try(var.infra.masters.extra_disks, [])) == 0 && length(try(var.infra.workers.extra_disks, [])) == 0
    error_message = "OVH v1 does not support extra disks yet."
  }

  validation {
    condition     = var.infra.masters.disk_size == 40 && var.infra.workers.disk_size == 40
    error_message = "OVH v1 does not support custom root disk sizing yet; keep disk_size at the default value of 40."
  }
}

###################################
# Network Config
###################################
variable "network" {
  description = "OVH network configuration"

  type = object({
    cidr                   = optional(string)
    load_balancer_flavor   = optional(string)
    kube_api_endpoint_mode = optional(string, "lb_ip")
    kube_api_dns_name      = optional(string)
  })

  default = {}

  validation {
    condition     = try(var.network.cidr, null) == null || can(cidrhost(var.network.cidr, 0))
    error_message = "network.cidr must be a valid CIDR block."
  }

  validation {
    condition     = contains(["dns", "lb_ip"], try(var.network.kube_api_endpoint_mode, "lb_ip"))
    error_message = "network.kube_api_endpoint_mode must be either 'dns' or 'lb_ip'."
  }

  validation {
    condition = (
      try(var.network.kube_api_endpoint_mode, "lb_ip") != "dns" ||
      (try(var.network.kube_api_dns_name, null) != null ? trimspace(var.network.kube_api_dns_name) != "" : false)
    )
    error_message = "network.kube_api_dns_name must be set when network.kube_api_endpoint_mode is 'dns'."
  }
}

check "ovh_multi_master_requires_private_network" {
  assert {
    condition = (
      var.infra.masters.count <= 1 ||
      trimspace(try(var.network.cidr, "")) != ""
    )
    error_message = "network.cidr must be set when infra.masters.count is greater than 1 so OVH multi-master can use the private-network path."
  }
}

check "ovh_private_network_cidr_has_enough_addresses" {
  assert {
    condition = (
      try(var.network.cidr, null) == null ||
      can(
        cidrhost(
          var.network.cidr,
          (tonumber(split("/", var.network.cidr)[1]) <= 28 ? 10 : 2) + var.infra.masters.count + var.infra.workers.count - 1
        )
      )
    )
    error_message = "network.cidr must provide enough private IP addresses for all OVH masters and workers."
  }
}

locals {
  env_root = "${path.module}/../../env"
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  os = var.os_catalog[var.os.selected]

  subdomain            = "${var.cluster.id}.${var.cluster.domain}"
  private_network_name = "${var.cluster.id}-${terraform.workspace}-private"
  private_subnet_name  = "${var.cluster.id}-${terraform.workspace}-subnet"

  master_details = [
    for i in range(var.infra.masters.count) : {
      name          = format("${local.os.hostname_prefix}-m%02d", i + 1)
      role          = "master"
      instance_size = var.infra.masters.instance_size
      disk_size     = var.infra.masters.disk_size
      extra_disks   = try(var.infra.masters.extra_disks, [])
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name          = format("${local.os.hostname_prefix}-w%02d", i + 1)
      role          = "worker"
      instance_size = var.infra.workers.instance_size
      disk_size     = var.infra.workers.disk_size
      extra_disks   = try(var.infra.workers.extra_disks, [])
    }
  ]

  masters_map = {
    for vm in local.master_details : vm.name => vm
  }

  workers_map = {
    for vm in local.worker_details : vm.name => vm
  }

  all_vms_map = merge(local.masters_map, local.workers_map)

  first_master_name = try(local.master_details[0].name, null)
  first_master_fqdn = local.first_master_name != null ? "${local.first_master_name}.${local.subdomain}" : null

  vm_disks = {
    for vm in concat(local.master_details, local.worker_details) :
    vm.name => [
      for i, disk in vm.extra_disks : {
        index      = i
        size_gb    = disk.size_gb
        mount_path = disk.mount_path
        filesystem = disk.filesystem
        label      = disk.label
        wwn = format(
          "0x6%015x",
          tonumber(regex("[0-9]+$", vm.name)) * 100 + i
        )
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

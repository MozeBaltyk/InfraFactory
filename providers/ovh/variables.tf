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
    os_name = string

    image = object({
      search_patterns = list(string)
    })

    default_instance_size = string
  }))

  default = {
    ubuntu24 = {
      os_name = "ubuntu"

      image = {
        search_patterns = [
          "ubuntu",
          "24.04"
        ]
      }

      default_instance_size = "b2-7"
    }

    ubuntu22 = {
      os_name = "ubuntu"

      image = {
        search_patterns = [
          "ubuntu",
          "22.04"
        ]
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
    node_name_format    = optional(string, "serial")
    cloud_init_selected = string
  })

  default = {
    id                  = "factory"
    domain              = "lab"
    timezone            = "Europe/Paris"
    region              = "GRA9"
    username            = "localadmin"
    node_name_format    = "serial"
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
  description = "Cluster networking"

  type = object({
    private = object({cidr = string})
    kube_api = optional(object({
      endpoint = optional(string, "lb_ip")

      dns = optional(object({
        name = string
      }))

      load_balancer = optional(object({
        enabled = optional(bool, false)
        flavor  = optional(string)
      }), {})
    }), {})
  })

  default = {
    private = {
      cidr = "10.0.0.0/24"
    }
  }
}

locals {
  env_root = "${path.module}/../../env"
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  os = var.os_catalog[var.os.selected]

  subdomain            = "${var.cluster.id}.${var.cluster.domain}"

  ## Private handling
  private_cidr        = var.network.private.cidr
  private_ip_host_offset_base = ( tonumber(split("/", local.private_cidr)[1]) <= 28 ? 10 : 2 )
  private_network_id = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  private_subnet_id = ovh_cloud_project_network_private_subnet_v2.cluster.id

  ## VM Topology Static
  master_details = [
    for i in range(var.infra.masters.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1)
        : format("%s-m%02d", var.cluster.id, i + 1)
      )
      role          = "master"
      instance_size = var.infra.masters.instance_size
      disk_size     = var.infra.masters.disk_size
      extra_disks   = try(var.infra.masters.extra_disks, [])
      private_ip = (cidrhost(local.private_cidr, local.private_ip_host_offset_base + i))
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1 + var.infra.masters.count)
        : format("%s-w%02d", var.cluster.id, i + 1)
      )
      role          = "worker"
      instance_size = var.infra.workers.instance_size
      disk_size     = var.infra.workers.disk_size
      extra_disks   = try(var.infra.workers.extra_disks, [])
      private_ip = (cidrhost(local.private_cidr, local.private_ip_host_offset_base + i + var.infra.masters.count))
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

  ## Kubernetes API bootstrap endpoint (first master private IP); overridden by LB when present
  kube_api_bootstrap_endpoint = local.master_details[0].private_ip
  ## Public-facing API endpoint for kubeconfig
  ## Resolution order:
  ##   1. Literal value when network.kube_api.endpoint is neither "lb_ip" nor "dns"
  ##   2. DNS name when network.kube_api.endpoint == "dns" and dns.name is set
  ##   3. First master's public IP (fallback)
  ##   4. First master's private IP (last resort)
  public_kube_api_endpoint = (
    !contains(["lb_ip", "dns"], var.network.kube_api.endpoint)
  ) ? var.network.kube_api.endpoint : (
    var.network.kube_api.endpoint == "dns" && try(var.network.kube_api.dns.name, "") != ""
    ? var.network.kube_api.dns.name
    : try(local.vm_public_ipv4_addresses[local.first_master_name], local.kube_api_bootstrap_endpoint)
  )

  ## Disks Topology
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
          tonumber(try(regex("[0-9]+$", vm.name), "0")) * 100 + i
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

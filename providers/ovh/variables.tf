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

variable "openstack" {
  description = "Optional OpenStack/OpenRC credentials for Talos image upload. If unset, OS_* environment variables or OS_CLOUD are used."
  sensitive   = true

  type = object({
    cloud                         = optional(string)
    auth_url                      = optional(string)
    user_name                     = optional(string)
    password                      = optional(string)
    tenant_name                   = optional(string)
    tenant_id                     = optional(string)
    user_domain_name              = optional(string)
    project_domain_name           = optional(string)
    application_credential_id     = optional(string)
    application_credential_name   = optional(string)
    application_credential_secret = optional(string)
    region                        = optional(string)
  })

  default = {}
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

    talos = {
      os_name = "talos"

      image = {
        search_patterns = ["talos"]
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
    id                      = string
    domain                  = string
    timezone                = string
    region                  = string
    username                = string
    node_name_format        = optional(string, "serial")
    cloud_init_selected     = string
    package_upgrade_enabled = optional(bool, true)
  })

  default = {
    id                      = "factory"
    domain                  = "lab"
    timezone                = "Europe/Paris"
    region                  = "GRA9"
    username                = "localadmin"
    node_name_format        = "serial"
    cloud_init_selected     = "k3s"
    package_upgrade_enabled = true
  }

  validation {
    condition     = contains(["default", "k3s", "rke2", "talos"], var.cluster.cloud_init_selected)
    error_message = "cluster.cloud_init_selected must be one of: default, k3s, rke2, talos."
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
      instance_size     = optional(string, "b2-7")
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
      instance_size     = optional(string, "b2-7")
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
      instance_size     = optional(string, "b2-7")
      ip_addresses      = optional(list(string), [])
      user_data_enabled = optional(bool, true)
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
    error_message = "OVH workers require at least one master node. Use infra.vms for VM-only deployments."
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
# OVH provider limitation: ovh/ovh v2.13.1 does not expose Public Cloud
# OpenStack security group resources/rules. SSH ingress (TCP/22) therefore
# cannot be restricted here without adding the OpenStack provider, which this
# provider intentionally avoids.
variable "network" {
  description = "Cluster networking"

  type = object({
    private = object({
      cidr    = string
      vlan_id = optional(number, 0)
      mode    = optional(string, "managed")
    })
    kube_api = optional(object({
      endpoint = optional(string, "public_ip")
      # Public CIDRs allowed to reach Kubernetes API (6443) and Talos API (50000) in Talos mode.
      ingress_cidrs = optional(list(string), ["0.0.0.0/0"])

      dns = optional(object({
        name = string
      }))

      load_balancer = optional(object({
        enabled          = optional(bool, false)
        flavor           = optional(string, "small")
        gateway_model    = optional(string, "s")
        ssh_jump_enabled = optional(bool, false)
        ssh_jump_port    = optional(number, 22)
      }), {})
    }), {})
  })

  default = {
    private = {
      cidr = "10.0.0.0/24"
    }
  }

  validation {
    condition     = contains(["managed", "existing"], var.network.private.mode)
    error_message = "network.private.mode must be either \"managed\" or \"existing\"."
  }

  validation {
    condition = alltrue([
      for cidr in try(var.network.kube_api.ingress_cidrs, []) : can(cidrnetmask(cidr))
    ])
    error_message = "network.kube_api.ingress_cidrs must contain valid IPv4 CIDR blocks."
  }
}

locals {
  env_root = "${path.module}/../../env"
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  is_talos           = var.cluster.cloud_init_selected == "talos"
  kubernetes_enabled = contains(["k3s", "rke2", "talos"], var.cluster.cloud_init_selected)

  ## Private handling
  private_network_mode     = var.network.private.mode
  private_network_managed  = local.private_network_mode == "managed"
  private_network_existing = local.private_network_mode == "existing"

  private_cidr                = var.network.private.cidr
  private_ip_host_offset_base = (tonumber(split("/", local.private_cidr)[1]) <= 28 ? 10 : 2)

  existing_private_network_matches = local.private_network_existing ? [
    for network in data.ovh_cloud_project_network_privates.existing[0].networks : network
    if network.vlan_id == var.network.private.vlan_id && length([
      for region in network.regions : region
      if region.region == var.cluster.region
    ]) == 1
  ] : []

  existing_private_network_global_id = local.private_network_existing ? try(local.existing_private_network_matches[0].id, null) : null

  existing_private_network_openstack_id = local.private_network_existing ? try(one([
    for region in local.existing_private_network_matches[0].regions : region.openstack_id
    if region.region == var.cluster.region
  ]), null) : null

  existing_private_subnet_matches = local.private_network_existing && local.existing_private_network_global_id != null ? [
    for subnet in data.ovh_cloud_project_network_private_subnets.existing[0].subnets : subnet
    if subnet.cidr == local.private_cidr
  ] : []

  existing_private_subnet_id = local.private_network_existing ? try(local.existing_private_subnet_matches[0].id, null) : null

  private_network_id = local.private_network_managed ? ovh_cloud_project_network_private.cluster[0].regions_openstack_ids[var.cluster.region] : local.existing_private_network_openstack_id
  private_subnet_id  = local.private_network_managed ? ovh_cloud_project_network_private_subnet_v2.cluster[0].id : local.existing_private_subnet_id

  ## Load Balancer
  lb_enabled             = local.kubernetes_enabled && var.infra.masters.count > 0 && try(var.network.kube_api.load_balancer.enabled, false)
  lb_ssh_jump_enabled    = local.lb_enabled && try(var.network.kube_api.load_balancer.ssh_jump_enabled, false)
  lb_ssh_jump_port       = try(var.network.kube_api.load_balancer.ssh_jump_port, 22)
  lb_floating_ip_address = try(ovh_cloud_project_loadbalancer.kube_api[0].floating_ip.ip, null)
  kube_api_ingress_cidrs = try(var.network.kube_api.ingress_cidrs, ["0.0.0.0/0"])
  lb_flavor_id = local.lb_enabled ? one([
    for f in data.ovh_cloud_project_loadbalancer_flavors.lb[0].flavors :
    f.id if f.name == var.network.kube_api.load_balancer.flavor
  ]) : null

  ## VM Topology Static
  master_details = [
    for i in range(var.infra.masters.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1)
        : format("%s-m%02d", var.cluster.id, i + 1)
      )
      role              = "master"
      instance_size     = var.infra.masters.instance_size
      disk_size         = var.infra.masters.disk_size
      extra_disks       = try(var.infra.masters.extra_disks, [])
      user_data_enabled = var.infra.masters.user_data_enabled
      private_ip        = (cidrhost(local.private_cidr, local.private_ip_host_offset_base + i))
      private_attach    = true
      public_attach     = true
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1 + var.infra.masters.count)
        : format("%s-w%02d", var.cluster.id, i + 1)
      )
      role              = "worker"
      instance_size     = var.infra.workers.instance_size
      disk_size         = var.infra.workers.disk_size
      extra_disks       = try(var.infra.workers.extra_disks, [])
      user_data_enabled = var.infra.workers.user_data_enabled
      private_ip        = (cidrhost(local.private_cidr, local.private_ip_host_offset_base + i + var.infra.masters.count))
      private_attach    = true
      public_attach     = true
    }
  ]

  masters_map = {
    for vm in local.master_details : vm.name => vm
  }

  workers_map = {
    for vm in local.worker_details : vm.name => vm
  }

  vm_details = [
    for i in range(var.infra.vms.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1 + var.infra.masters.count + var.infra.workers.count)
        : format("%s-v%02d", var.cluster.id, i + 1)
      )
      role              = "vm"
      instance_size     = var.infra.vms.instance_size
      user_data_enabled = var.infra.vms.user_data_enabled
      private_ip        = local.private_network_existing ? var.infra.vms.ip_addresses[i] : cidrhost(local.private_cidr, local.private_ip_host_offset_base + i + var.infra.masters.count + var.infra.workers.count)
      private_attach    = true
      public_attach     = true
    }
  ]

  vms_map = {
    for vm in local.vm_details : vm.name => vm
  }

  all_vms_map = merge(local.masters_map, local.workers_map, local.vms_map)

  first_master_name = try(local.master_details[0].name, null)
  first_master_fqdn = local.first_master_name != null ? "${local.first_master_name}.${local.subdomain}" : null

  ## Kubernetes API bootstrap endpoint (first master private IP); overridden by LB when present
  kube_api_bootstrap_endpoint = try(local.master_details[0].private_ip, null)
  ## Public-facing API endpoint for kubeconfig
  ## Resolution order:
  ##   1. Load Balancer floating IP when network.kube_api.endpoint == "lb_ip" and LB exists
  ##   2. DNS name when network.kube_api.endpoint == "dns" and dns.name is set
  ##   3. First master's public IP when endpoint == "public_ip" or as fallback
  ##   4. Literal value when network.kube_api.endpoint is not a known mode
  ##   5. First master's private IP (last resort)
  public_kube_api_endpoint = (
    var.network.kube_api.endpoint == "lb_ip" && local.lb_floating_ip_address != null
    ) ? local.lb_floating_ip_address : (
    var.network.kube_api.endpoint == "dns" && try(var.network.kube_api.dns.name, "") != ""
    ) ? var.network.kube_api.dns.name : (
    var.network.kube_api.endpoint == "public_ip" || contains(["lb_ip", "dns"], var.network.kube_api.endpoint)
    ? try(local.vm_public_ipv4_addresses[local.first_master_name], local.kube_api_bootstrap_endpoint, null)
    : var.network.kube_api.endpoint
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

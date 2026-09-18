##
## OVH credentials
##
variable "infra_provider" {
  type    = string
  default = "OVH"

  validation {
    condition     = var.infra_provider == "OVH"
    error_message = "infra_provider must be OVH."
  }
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
  nullable    = true
  default     = null
}

variable "ovh_application_secret" {
  description = "OVH application secret"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
}

variable "ovh_consumer_key" {
  description = "OVH consumer key"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
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
    condition     = contains(["default", "k3s", "rke2"], var.cluster.cloud_init_selected)
    error_message = "cluster.cloud_init_selected must be one of: default, k3s, rke2."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,53}[A-Za-z0-9])?$", var.cluster.id))
    error_message = "cluster.id must be a valid single DNS label of at most 55 characters."
  }

  validation {
    condition     = length(var.cluster.domain) <= 253 && can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$", var.cluster.domain))
    error_message = "cluster.domain must be a valid DNS domain of at most 253 characters."
  }

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.cluster.username))
    error_message = "cluster.username must be a valid Linux/SSH username (lowercase, at most 32 characters)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)?$", var.cluster.timezone))
    error_message = "cluster.timezone must be a simple timezone name such as UTC or Europe/Paris."
  }

  validation {
    condition     = contains(["serial", "role"], var.cluster.node_name_format)
    error_message = "cluster.node_name_format must be either serial or role."
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
      nfs            = optional(list(string), [])
      object_storage = optional(list(string), [])
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
      nfs            = optional(list(string), [])
      object_storage = optional(list(string), [])
    })

    vms = optional(object({
      count             = number
      instance_size     = optional(string, "b2-7")
      user_data_enabled = optional(bool, true)
      nfs               = optional(list(string), [])
      object_storage    = optional(list(string), [])
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
# OVH-managed storage provisioning
###################################
# `storage.Object-storage` is a hyphenated attribute name, which HCL's
# `object({...})` type syntax cannot express (map keys in a type spec must be
# plain identifiers). The variable is therefore left untyped (`any`) and
# normalized/validated in storage.tf and checks.tf instead.
variable "storage" {
  description = <<-EOT
    OVH-managed storage, keyed by a logical name that infra.masters/workers/vms
    reference via their `nfs`/`object_storage` attachment lists:
      NFS = optional map of Public Cloud File Storage shares
        key => { name, size (GB), type = "STANDARD_1AZ", network_id, subnet_id, description,
                 mount_path, options, read_only }
      Object-storage = optional map of S3-compatible buckets
        key => { name, region ("GRA"|"SBG"|"BHS"), versioning, tags, object_lock, encryption }
  EOT
  type        = any
  default     = {}
}

###################################
# Network Config
###################################
variable "network" {
  description = "Cluster networking"

  type = object({
    private = object({
      cidr    = string
      vlan_id = optional(number, 0)
    })
    kube_api = optional(object({
      endpoint = optional(string, "public_ip")
      # Operator CIDRs allowed to reach SSH/Kubernetes APIs as applicable.
      ingress_cidrs = optional(list(string), [])

      dns = optional(object({
        name = string
      }))

      load_balancer = optional(object({
        enabled            = optional(bool, false)
        flavor             = optional(string, "small")
        gateway_model      = optional(string, "s")
        ingress_http_port  = optional(number, 80)
        ingress_https_port = optional(number, 443)
        # Explicit CIDRs for workload ingress (80/443). Null falls back
        # to the API ingress CIDRs; there is no public-open default.
        ingress_cidrs = optional(list(string))
      }), {})
    }), {})
  })

  default = {
    private = {
      cidr = "10.0.0.0/24"
    }
  }

  validation {
    condition = alltrue([
      for cidr in try(var.network.kube_api.ingress_cidrs, []) :
      can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "network.kube_api.ingress_cidrs must contain valid IPv4 CIDR blocks."
  }

  validation {
    condition = alltrue([
      for cidr in coalesce(try(var.network.kube_api.load_balancer.ingress_cidrs, null), []) :
      can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "network.kube_api.load_balancer.ingress_cidrs must contain valid IPv4 CIDR blocks."
  }

  validation {
    condition = alltrue([
      for p in [
        try(var.network.kube_api.load_balancer.ingress_http_port, 80),
        try(var.network.kube_api.load_balancer.ingress_https_port, 443),
      ] : p >= 1 && p <= 65535
    ])
    error_message = "network.kube_api.load_balancer.ingress_http_port/ingress_https_port must be valid TCP ports (1-65535)."
  }
}

# Standalone bastion (own state, serves many clusters). Null = no jump mode,
# public topology unchanged. Convention: bastion username == cluster username;
# bastion private IP is the shared reserved address (module.ipam.bastion_ip).
variable "bastion" {
  description = "Standalone bastion reference (null disables SSH jump mode)"
  type = object({
    public_ip = string
  })
  default  = null
  nullable = true

  validation {
    condition     = var.bastion == null || can(cidrhost("${var.bastion.public_ip}/32", 0))
    error_message = "bastion.public_ip must be a valid IPv4 address."
  }
}

# Caller's current public IP, used below to auto-allow kube-api/SSH ingress
# for whoever is running `tofu apply` (see local.my_public_ip).
data "http" "my_ip" {
  count = local.kubernetes_enabled ? 1 : 0

  url = "http://ifconfig.me/ip"
}

locals {
  env_root = abspath("${path.module}/../../../env")
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  kubernetes_enabled = contains(["k3s", "rke2"], var.cluster.cloud_init_selected)

  # Auto-detected caller public IP, appended to the explicit
  # network.kube_api.ingress_cidrs below so the operator running `tofu
  # apply` doesn't lock themselves out; it never substitutes for an explicit
  # entry (see the validate_operator_ingress_cidrs precondition in checks.tf).
  my_public_ip = local.kubernetes_enabled ? "${chomp(trimspace(data.http.my_ip[0].response_body))}/32" : null

  ## Private handling (managed only: the cluster always owns its network)
  private_cidr                = var.network.private.cidr
  private_ip_host_offset_base = (tonumber(split("/", local.private_cidr)[1]) <= 28 ? 10 : 2)

  private_network_id = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  private_subnet_id  = ovh_cloud_project_network_private_subnet_v2.cluster.id
  private_gateway_ip = ovh_cloud_project_network_private_subnet_v2.cluster.gateway_ip

  ## Load Balancer
  # Kubernetes nodes are ALWAYS jump-mode (private-only, via the standalone
  # bastion): there is no public topology for k3s/rke2 on OVH anymore.
  # Enforced by the validate_k8s_topology preconditions in bastion.tf
  # (bastion set + LB enabled + lb_ip/dns endpoint); plain VM-only shapes
  # evaluate exactly as before.
  k8s_nodes  = local.kubernetes_enabled && var.infra.masters.count > 0
  lb_enabled = local.k8s_nodes && try(var.network.kube_api.load_balancer.enabled, false)
  # Standalone bastion addresses: public IP is the input, private IP is the
  # shared reserved address (last usable host of the CIDR, no shared state).
  bastion_public_ipv4_address = try(var.bastion.public_ip, null)
  bastion_private_ip          = module.ipam.bastion_ip
  lb_floating_ip_address      = try(ovh_cloud_floating_ip.kube_api[0].id, null)
  # Explicit CIDRs plus the caller's auto-detected current IP; deduplicated
  # in case the operator already listed it explicitly.
  kube_api_ingress_cidrs = distinct(concat(
    try(var.network.kube_api.ingress_cidrs, []),
    local.my_public_ip != null ? [local.my_public_ip] : [],
  ))
  # Workload ingress (80/443) audience: explicit per-LB override, else the
  # API audience. Never public-open by default.
  lb_ingress_cidrs = distinct(coalesce(
    try(var.network.kube_api.load_balancer.ingress_cidrs, null),
    try(var.network.kube_api.ingress_cidrs, []),
  ))
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
      private_ip        = module.ipam.master_ips[i]
      private_attach    = true
      public_attach     = !local.k8s_nodes
      nfs               = try(var.infra.masters.nfs, [])
      object_storage    = try(var.infra.masters.object_storage, [])
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
      private_ip        = module.ipam.worker_ips[i]
      private_attach    = true
      public_attach     = !local.k8s_nodes
      nfs               = try(var.infra.workers.nfs, [])
      object_storage    = try(var.infra.workers.object_storage, [])
    }
  ]

  masters_map = {
    for vm in local.master_details : vm.name => vm
  }

  workers_map = {
    for vm in local.worker_details : vm.name => vm
  }

  cluster_vms_map = merge(local.masters_map, local.workers_map)

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
      private_ip        = module.ipam.vm_ips[i]
      private_attach    = true
      public_attach     = true
      nfs               = try(var.infra.vms.nfs, [])
      object_storage    = try(var.infra.vms.object_storage, [])
    }
  ]

  vms_map = {
    for vm in local.vm_details : vm.name => vm
  }

  all_vms_map = merge(local.masters_map, local.workers_map, local.vms_map)
  # K8s masters/workers (private-only; see moved.tf for the state-mv note
  # from the single-resource merge).
  private_cluster_vms_map = local.k8s_nodes ? local.cluster_vms_map : {}

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

}

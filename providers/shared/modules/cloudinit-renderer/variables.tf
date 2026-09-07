###
### Cloud-init renderer: renders the shared cloud-init user-data for every VM.
###
### Renders the shared `providers/shared/cloud-init/<selected>/cloud_init.cfg.tftpl`
### template once per VM. Provider-specific inputs (IPs, TLS SANs, first-master
### detection) are computed by the caller and passed in via `vms`; the shared
### cluster/package/token surface is passed as module inputs.
###

variable "cloud_init_selected" {
  description = "Shared cloud-init variant: default, k3s or rke2."
  type        = string
}

variable "node_username" {
  description = "User created on the nodes by cloud-init."
  type        = string
}

variable "timezone" {
  description = "Timezone configured on the nodes."
  type        = string
}

variable "extra_packages" {
  description = "Extra packages installed on the nodes by cloud-init."
  type        = list(string)
  default     = []
}

variable "public_key" {
  description = "Public SSH key injected into the nodes."
  type        = string
}

variable "cluster_token" {
  description = "Shared k3s/rke2 cluster join token."
  type        = string
  sensitive   = true
}

variable "package_upgrade_enabled" {
  description = "Whether cloud-init runs package upgrade on first boot."
  type        = bool
  default     = false
}

###################################
# NFS server variables
###################################
variable "nfs" {
  description = "Optional NFS server exported by the nodes listed in nfs.nodes."
  type = object({
    enabled      = optional(bool, false)
    nodes        = optional(list(string), [])
    export_path  = optional(string, "/srv/nfs/shared")
    allowed_cidr = optional(string, "*")
    read_only    = optional(bool, false)
  })
  default = {}

  validation {
    condition     = !var.nfs.enabled || length(var.nfs.nodes) > 0
    error_message = "nfs.enabled requires at least one node name in nfs.nodes."
  }

  validation {
    condition     = can(regex("^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$", var.nfs.export_path))
    error_message = "nfs.export_path must be an absolute path such as /srv/nfs/shared."
  }

  validation {
    condition     = var.nfs.allowed_cidr == "*" || can(cidrhost(var.nfs.allowed_cidr, 0))
    error_message = "nfs.allowed_cidr must be \"*\" or a valid CIDR such as 10.0.0.0/24."
  }
}

###################################
# K3s specific variables
###################################
variable "k3s" {
  description = "K3s cluster configuration."
  type = object({
    version                = optional(string, "latest")
    data_dir               = optional(string, null)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    traefik_enabled        = optional(bool, true)
    servicelb_enabled      = optional(bool, true)
    local_storage_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    flannel_enabled        = optional(bool, true)
  })
  default = {}
}

###################################
# RKE2 specific variables
###################################
variable "rke2" {
  description = "RKE2 cluster configuration."
  type = object({
    version                = optional(string, "latest")
    data_dir               = optional(string, null)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    ingress_nginx_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    cni                    = optional(string, null)
    ingress_type           = optional(string, null)
    kube_proxy_enabled     = optional(bool, null)
    cilium = optional(object({
      hubble_enabled    = optional(bool, false)
      operator_replicas = optional(number, 1)
      l2announcements = optional(object({
        enabled           = optional(bool, false)
        lb_pool_start     = optional(string, null)
        lb_pool_end       = optional(string, null)
        network_interface = optional(string, null)
      }), {})
    }), {})
  })
  default = {}
}

###################################
# Ansible Pull specific variables
###################################
variable "ansible" {
  description = "Optional ansible-pull configuration."
  type = object({
    pull = optional(object({
      repo     = optional(string, null)
      branch   = optional(string, null)
      playbook = optional(string, null)
      token    = optional(string, null)
      timer    = optional(string, null)
    }), null)
  })
  default = {}
}

variable "vms" {
  description = "Per-VM inputs consumed by the shared cloud-init template."
  type = map(object({
    hostname           = string
    fqdn               = string
    domain             = string
    node_role          = string
    is_first_master    = bool
    first_master_ip    = optional(string, null)
    current_private_ip = optional(string, null)
    # Interface RKE2's Canal/Flannel backend should bind to (e.g. "ens4" on
    # OVH's dual-NIC layout). Left null on providers where the default
    # (public-route) interface is already fully reachable node-to-node.
    flannel_iface = optional(string, null)
    extra_disks = list(object({
      wwn        = string
      mount_path = string
      filesystem = string
    }))
    k3s_tls_sans  = list(string)
    rke2_tls_sans = list(string)
    # Per-VM override of the shared variant (e.g. standalone infra.vms use "default").
    cloud_init_selected = optional(string, null)
  }))
}

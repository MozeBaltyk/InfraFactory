################################
# Extra Packages installed on the nodes by cloud-init
################################
variable "extra_packages" {
  description = "Extra packages to be installed on the nodes by cloud-init"
  type        = list(string)
  default     = []
}

###################################
# K3s specific variables
###################################
variable "k3s" {
  description = "K3s cluster configuration"

  type = object({
    version                = optional(string, "latest")
    data_dir               = optional(string)
    token                  = optional(string)
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
# rke2 specific variables
###################################
variable "rke2" {
  description = "RKE2 cluster configuration"

  type = object({
    version                = optional(string, "latest") #"v1.35.1+rke2r1"
    data_dir               = optional(string)
    token                  = optional(string)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    ingress_nginx_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    kube_proxy_enabled     = optional(bool, true)
    cni                    = optional(string) # "calico", "canal", "cilium", "none" (null = RKE2 default)
    ingress_type           = optional(string) # "ingress-nginx", "traefik", "cilium", "none" (null = RKE2 default)
    cilium = optional(object({
      hubble_enabled    = optional(bool, false) # Enable Hubble observability (only with cni="cilium")
      operator_replicas = optional(number, 1)   # Cilium operator replicas when kube-proxy is disabled
      l2announcements = optional(object({
        enabled           = optional(bool, false) # Enable Cilium L2 announcements (only with cni="cilium")
        lb_pool_start     = optional(string)      # Start of the load balancer IP pool
        lb_pool_end       = optional(string)      # End of the load balancer IP pool
        network_interface = optional(string)      # Network interface to use for L2 announcements (e.g., "eth0")
      }), {})
    }), {})
  })

  default = {}

  validation {
    condition     = var.rke2.cni == null ? true : contains(["calico", "canal", "cilium", "none"], var.rke2.cni)
    error_message = "RKE2 cni must be one of: \"calico\", \"canal\", \"cilium\", \"none\", or null (for RKE2 default)."
  }

  validation {
    condition     = var.rke2.ingress_type == null ? true : contains(["ingress-nginx", "traefik", "cilium", "none"], var.rke2.ingress_type)
    error_message = "RKE2 ingress_type must be one of: \"ingress-nginx\", \"traefik\", \"cilium\", \"none\", or null (for RKE2 default)."
  }

  validation {
    condition     = var.rke2.ingress_type == "cilium" ? var.rke2.cni == "cilium" : true
    error_message = "RKE2 ingress_type \"cilium\" requires rke2.cni to also be \"cilium\"."
  }

  validation {
    condition     = var.rke2.cilium.operator_replicas >= 1 && floor(var.rke2.cilium.operator_replicas) == var.rke2.cilium.operator_replicas
    error_message = "RKE2 cilium.operator_replicas must be an integer greater than or equal to 1."
  }

  validation {
    condition     = !try(var.rke2.cilium.l2announcements.enabled, false) || var.rke2.cni == "cilium"
    error_message = "RKE2 cilium.l2announcements.enabled requires rke2.cni to be \"cilium\"."
  }

  validation {
    condition     = !try(var.rke2.cilium.l2announcements.enabled, false) || !var.rke2.kube_proxy_enabled
    error_message = "RKE2 cilium.l2announcements.enabled requires rke2.kube_proxy_enabled to be false."
  }

  validation {
    condition = !try(var.rke2.cilium.l2announcements.enabled, false) || alltrue([
      try(var.rke2.cilium.l2announcements.lb_pool_start != null && trimspace(var.rke2.cilium.l2announcements.lb_pool_start) != "", false),
      try(var.rke2.cilium.l2announcements.lb_pool_end != null && trimspace(var.rke2.cilium.l2announcements.lb_pool_end) != "", false),
      try(var.rke2.cilium.l2announcements.network_interface != null && trimspace(var.rke2.cilium.l2announcements.network_interface) != "", false),
    ])
    error_message = "RKE2 cilium.l2announcements.enabled requires lb_pool_start, lb_pool_end, and network_interface to be set."
  }
}

###################################
# Ansible Pull specific variables
###################################
variable "ansible" {
  type = object({
    pull = optional(object({
      repo     = string
      branch   = string
      playbook = string
      token    = optional(string)
      timer    = optional(string)
    }))
  })
  default = {}
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
      NFS = optional map of Public Cloud File Storage shares (ovh_cloud_storage_file_share)
        key => { name, size (GB), type = "STANDARD_1AZ", network_id, subnet_id, description,
                 mount_path, options, read_only }
        network_id/subnet_id default to the cluster's managed private network/subnet;
        mount_path/options/read_only default the client mount for every VM that
        attaches this key via infra.*.nfs.
      Object-storage = optional map of S3-compatible buckets (ovh_cloud_project_storage)
        key => { name, region ("GRA"|"SBG"|"BHS"), versioning, tags, object_lock, encryption }
  EOT
  type        = any
  default     = {}
}

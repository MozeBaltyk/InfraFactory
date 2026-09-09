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
# Object Storage (S3-compatible) credentials
###################################
variable "object_storage_credentials" {
  description = "Optional Object Storage (S3-compatible) credentials written as an env file on the nodes listed in each entry's nodes."
  type = list(object({
    # VM names (from `vms`) that should receive this credential file.
    nodes             = list(string)
    name              = string # logical key; file is written to /etc/infrafactory/object-storage/<name>.env
    bucket            = string
    region            = string
    endpoint          = string
    access_key_id     = string
    secret_access_key = string
  }))
  default   = []
  sensitive = true
}

###################################
# NFS client variables
###################################
variable "nfs" {
  description = "Optional NFS client mounts attached on the nodes listed in each nfs.client.mounts[*].nodes."
  type = object({
    client = optional(object({
      mounts = optional(list(object({
        # VM names (from `vms`) that should mount this share.
        nodes = list(string)
        # NFS server address: another node's hostname/IP, or an OVH-managed
        # Public Cloud File Storage share endpoint (see `storage.NFS`).
        server      = string
        export_path = string
        mount_path  = string
        options     = optional(string, "defaults,_netdev")
        read_only   = optional(bool, false)
      })), [])
    }), {})
  })
  default = {}

  validation {
    condition     = alltrue([for m in var.nfs.client.mounts : length(m.nodes) > 0])
    error_message = "nfs.client.mounts[*].nodes must list at least one target VM name."
  }

  validation {
    condition     = alltrue([for m in var.nfs.client.mounts : can(regex("^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$", m.mount_path))])
    error_message = "nfs.client.mounts[*].mount_path must be an absolute path."
  }

  validation {
    condition     = alltrue([for m in var.nfs.client.mounts : trimspace(m.server) != "" && trimspace(m.export_path) != ""])
    error_message = "nfs.client.mounts[*].server and export_path must not be empty."
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

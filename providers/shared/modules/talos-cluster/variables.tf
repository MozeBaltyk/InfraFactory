###
### Talos cluster orchestration module.
###
### Applies machine configurations, bootstraps the cluster, waits for health and
### returns the kubeconfig. Used by every provider that supports the "talos"
### cloud-init variant. Provider-specific concerns stay at the call site:
###   - image provisioning (the module does not download images)
###   - the nodes map (operator endpoint -> role) built from provider resources
###   - config_patches (e.g. libvirt installs onto /dev/vda)
###   - depends_on for the provider's VM resource
###

variable "cluster_name" {
  description = "Cluster name (used as talosctl context)."
  type        = string
}

variable "talos_version" {
  description = "Talos Linux version, e.g. v1.13.7."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for generated Talos machine configs. Null uses Talos provider default."
  type        = string
  default     = null
}

variable "kube_api_endpoint" {
  description = "Kubernetes API endpoint address (no scheme, no port)."
  type        = string
}

variable "nodes" {
  description = "Map of stable node name to node settings. Endpoint may be known only after apply."
  type = map(object({
    endpoint = string
    role     = string
    hostname = optional(string)
    extra_disks = optional(list(object({
      wwn        = string
      mount_path = string
      filesystem = string
      label      = string
    })), [])
  }))

  validation {
    condition     = alltrue([for node in var.nodes : contains(["master", "worker"], node.role)])
    error_message = "Node role must be either \"master\" or \"worker\"."
  }

  validation {
    condition = alltrue(flatten([
      for node in var.nodes : [
        for disk in node.extra_disks : can(regex("^[A-Za-z0-9-]{1,34}$", disk.label))
      ]
    ]))
    error_message = "Talos extra disk labels must be 1-34 chars and contain only letters, digits, and hyphens."
  }

  validation {
    condition = alltrue(flatten([
      for node in var.nodes : [
        for disk in node.extra_disks : contains(["ext4", "xfs"], disk.filesystem)
      ]
    ]))
    error_message = "Talos extra disk filesystems must be either \"ext4\" or \"xfs\"."
  }
}

variable "first_master_node" {
  description = "Operator endpoint of the first master (bootstrap + kubeconfig node)."
  type        = string
}

variable "config_patches" {
  description = "Machine configuration patches applied to every node."
  type        = list(string)
  default     = []
}

variable "controlplane_config_patches" {
  description = "Machine configuration patches applied only to control-plane nodes."
  type        = list(string)
  default     = []
}

variable "worker_config_patches" {
  description = "Machine configuration patches applied only to worker nodes."
  type        = list(string)
  default     = []
}

variable "cni" {
  description = "Talos-managed CNI name. Null uses Talos default."
  type        = string
  default     = null
}

variable "allow_scheduling_on_control_planes" {
  description = "Allow workloads on Talos control-plane nodes. Null uses Talos default."
  type        = bool
  default     = null
}

variable "env_path" {
  description = "Directory where kubeconfig and talosconfig are written."
  type        = string
}

variable "write_local_artifacts" {
  description = "Write kubeconfig/talosconfig to env_path (false in gitops mode)."
  type        = bool
  default     = true
}

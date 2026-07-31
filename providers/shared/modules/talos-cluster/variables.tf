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

variable "kube_api_endpoint" {
  description = "Kubernetes API endpoint address (no scheme, no port)."
  type        = string
}

variable "nodes" {
  description = "Map of operator endpoint to role (\"master\" or \"worker\")."
  type        = map(string)
}

variable "first_master_node" {
  description = "Operator endpoint of the first master (bootstrap + kubeconfig node)."
  type        = string
}

variable "config_patches" {
  description = "Provider-specific machine configuration patches."
  type        = list(string)
  default     = []
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

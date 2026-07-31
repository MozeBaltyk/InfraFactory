###
### Ansible artifacts module.
###
### Renders hosts.ini + ansible.cfg into the environment directory and runs the
### shared ansible-pull-free provisioning flow: cloud-init readiness check,
### kube-apiserver TLS SAN reconciliation and kubeconfig fetch. Provider-specific
### inputs (node IPs, first-master SSH host, kube API endpoint) are computed by
### the caller; provider VM resources are wired via depends_on on the module
### block.
###

variable "env_path" {
  description = "Directory where hosts.ini, ansible.cfg and kubeconfig are written."
  type        = string
}

variable "cluster_id" {
  description = "Cluster name/id."
  type        = string
}

variable "username" {
  description = "SSH user for the nodes."
  type        = string
}

variable "cloud_init_selected" {
  description = "Shared cloud-init variant: default, k3s or rke2."
  type        = string
}

variable "kube_api_endpoint" {
  description = "Kubernetes API endpoint address (no scheme, no port)."
  type        = string
}

variable "ssh_host" {
  description = "Operator-reachable SSH host of the first master."
  type        = string
}

variable "controller_ips" {
  description = "Operator-reachable IPs of the control plane nodes."
  type        = list(string)
}

variable "worker_ips" {
  description = "Operator-reachable IPs of the worker nodes."
  type        = list(string)
}

variable "write_local_artifacts" {
  description = "Write hosts.ini/ansible.cfg to env_path (false in gitops mode)."
  type        = bool
  default     = true
}

variable "gitops_mode" {
  description = "Expose rendered artifacts via outputs instead of local files."
  type        = bool
  default     = false
}

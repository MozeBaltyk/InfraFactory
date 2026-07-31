variable "env_path" {
  description = "Absolute path to the environment directory (artifacts are written here)"
  type        = string
}

variable "write_local_artifacts" {
  description = "Write SSH keys and token files to env_path"
  type        = bool
  default     = true
}

variable "gitops_mode" {
  description = "Expose secrets as outputs for GitOps (writeOutputsToSecret) instead of local files"
  type        = bool
  default     = false
}

variable "cloud_init_selected" {
  description = "Selected cloud-init type (k3s, rke2, default, talos) - determines the token source"
  type        = string
  default     = "k3s"
}

variable "k3s_token" {
  description = "K3s cluster token (optional; a random one is generated if unset)"
  type        = string
  default     = null
}

variable "rke2_token" {
  description = "RKE2 cluster token (optional; a random one is generated if unset)"
  type        = string
  default     = null
}

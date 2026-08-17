###
### SSH keys, cluster token and environment directory (shared module)
###

module "ssh_keys" {
  source = "../shared/modules/ssh-keys"

  env_path              = local.env_path
  write_local_artifacts = local.write_local_artifacts && !local.is_talos
  gitops_mode           = local.gitops_mode
  cloud_init_selected   = var.cluster.cloud_init_selected
  k3s_token             = var.k3s.token
  rke2_token            = var.rke2.token
}

###
### Outputs for GitOps mode (writeOutputsToSecret: true) - otherwise null
###

output "gitops_ssh_private_key_pem" {
  description = "GitOps-mode SSH private key for cluster access."
  sensitive   = true
  value       = module.ssh_keys.gitops_ssh_private_key_pem
}

output "gitops_ssh_public_key_openssh" {
  description = "GitOps-mode SSH public key for cluster access."
  value       = module.ssh_keys.gitops_ssh_public_key_openssh
}

output "gitops_cluster_token" {
  description = "GitOps-mode generated cluster token."
  sensitive   = true
  value       = module.ssh_keys.gitops_cluster_token
}

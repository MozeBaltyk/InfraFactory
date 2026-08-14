###
### SSH keys, cluster token and environment directory (shared module)
###

module "ssh_keys" {
  # Talos has no sshd, but jump mode still needs the operator keys for the
  # bastion (ssh_config identity + bastion cloud-init) and the SSH tunnels.
  count  = local.is_talos && !local.lb_ssh_jump_enabled ? 0 : 1
  source = "../shared/modules/ssh-keys"

  env_path            = local.env_path
  cloud_init_selected = var.cluster.cloud_init_selected
  k3s_token           = var.k3s.token
  rke2_token          = var.rke2.token
}

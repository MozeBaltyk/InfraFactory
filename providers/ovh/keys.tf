###
### SSH keys, cluster token and environment directory (shared module)
###

module "ssh_keys" {
  count  = local.is_talos ? 0 : 1
  source = "../shared/modules/ssh-keys"

  env_path            = local.env_path
  cloud_init_selected = var.cluster.cloud_init_selected
  k3s_token           = var.k3s.token
  rke2_token          = var.rke2.token
}

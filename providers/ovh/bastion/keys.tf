###
### Bootstrap keypair (bastion-first). Operator-provided keys win; otherwise
### the shared ssh-keys module generates a keypair into the workspace env dir
### (env/OVH/<BASTION_ENV>/.key.{pub,private}), the same artifact convention as
### the cluster stack. The effective pubkey seeds authorized_keys + the Nova
### keypair at birth; the effective private key is the readiness-probe key.
###
### Either both admin_public_keys and probe_ssh_private_key_path are provided,
### or neither (auto-generate). Mixed states are rejected by a precondition on
### terraform_data.validate_bastion (main.tf).
###

locals {
  env_root = abspath("${path.module}/../../../env")
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  use_provided_keys = length(var.admin_public_keys) > 0

  # one() over the splat is null-safe when the module is absent (count = 0).
  generated_public_key = one(module.ssh_keys[*].public_key_openssh)

  admin_public_keys = local.use_provided_keys ? var.admin_public_keys : [local.generated_public_key]

  probe_ssh_private_key_path = var.probe_ssh_private_key_path != null ? var.probe_ssh_private_key_path : abspath("${local.env_path}/.key.private")
}

# Auto-generated keypair: the shared module writes .key.{pub,private}. The
# cluster token is disabled — a bastion holds no cluster, so .token is
# meaningless; instead we emit a one-host inventory + ansible.cfg below.
module "ssh_keys" {
  source = "../../shared/modules/ssh-keys"
  count  = local.use_provided_keys ? 0 : 1

  env_path            = local.env_path
  write_cluster_token = false
}

###
### Day-2 operator artifacts for the bastion itself: a one-host inventory and
### ansible.cfg so it can be driven directly with ansible (it has no cluster
### nodes, so no CONTROLLERS/WORKERS groups and no kubeconfig). Reach it over
### its public IP with the admin key — no ProxyCommand.
###

locals {
  bastion_hosts_ini = "[bastion]\n${local.bastion_public_ipv4_address}\n"

  bastion_ansible_cfg = <<-EOT
[defaults]
remote_user = ${var.bastion.username}
inventory = ./hosts.ini
host_key_checking = false
deprecation_warnings = false
private_key_file = ./.key.private
EOT
}

resource "local_file" "bastion_hosts_ini" {
  filename        = "${local.env_path}/hosts.ini"
  content         = local.bastion_hosts_ini
  file_permission = "0644"

  depends_on = [terraform_data.validate_bastion_public_ip]
}

resource "local_file" "bastion_ansible_cfg" {
  filename        = "${local.env_path}/ansible.cfg"
  content         = local.bastion_ansible_cfg
  file_permission = "0644"
}

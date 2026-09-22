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

# ponytail: the module also writes an unused .token next to the keys; the
# cluster token is meaningless for a bastion but harmless (gitignored). A
# token toggle in the shared module can drop it if it ever bothers anyone.
module "ssh_keys" {
  source = "../../shared/modules/ssh-keys"
  count  = local.use_provided_keys ? 0 : 1

  env_path = local.env_path
}

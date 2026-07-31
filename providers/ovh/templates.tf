# Render shared cloud-init user-data for all nodes
module "cloudinit" {
  source = "../shared/modules/cloudinit-renderer"

  cloud_init_selected = var.cluster.cloud_init_selected
  node_username       = var.cluster.username
  timezone            = var.cluster.timezone
  extra_packages      = var.extra_packages
  public_key          = module.ssh_keys.public_key_openssh
  cluster_token       = module.ssh_keys.cluster_token
  k3s                 = var.k3s
  rke2                = var.rke2
  ansible             = var.ansible

  vms = {
    for vm in local.all_vms_map :
    vm.name => {
      hostname           = vm.name
      fqdn               = "${vm.name}.${local.subdomain}"
      domain             = local.subdomain
      node_role          = vm.role
      is_first_master    = vm.role == "master" && vm.name == local.first_master_name
      first_master_ip    = local.master_details[0].private_ip
      current_private_ip = vm.private_ip
      extra_disks        = try(local.vm_disks[vm.name], [])
      k3s_tls_sans = distinct(compact(concat(
        var.k3s.tls_sans,
        [local.master_details[0].private_ip],
        [local.first_master_fqdn],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )))
      rke2_tls_sans = distinct(compact(concat(
        var.rke2.tls_sans,
        [local.master_details[0].private_ip],
        [local.first_master_fqdn],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )))
    }
  }
}


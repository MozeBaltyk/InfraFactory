# Azure-specific template resources for VM provisioning

locals {
  public_kube_api_endpoint = azurerm_public_ip.vm-pip[local.first_master_name].ip_address
}

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
    for vm in concat(local.master_details, local.worker_details) :
    vm.name => {
      hostname           = vm.name
      fqdn               = "${vm.name}.${local.subdomain}"
      domain             = local.subdomain
      node_role          = vm.role
      is_first_master    = vm.name == local.master_details[0].name
      first_master_ip    = azurerm_network_interface.vm-interface[local.first_master_name].private_ip_address
      current_private_ip = azurerm_network_interface.vm-interface[vm.name].private_ip_address
      extra_disks        = try(local.vm_disks[vm.name], [])
      k3s_tls_sans = concat(var.k3s.tls_sans,
        [local.public_kube_api_endpoint],
        [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )
      rke2_tls_sans = concat(var.rke2.tls_sans,
        [local.public_kube_api_endpoint],
        [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )
    }
  }
}

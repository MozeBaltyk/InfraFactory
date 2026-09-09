# Azure-specific template resources for VM provisioning

locals {
  public_kube_api_endpoint = local.first_master_name != null ? azurerm_public_ip.vm-pip[local.first_master_name].ip_address : null
  first_master_fqdn        = local.first_master_name != null ? "${local.first_master_name}.${local.subdomain}" : null

  # NFS client mounts derived from infra.masters/workers/vms.nfs_mounts:
  # role membership is the target selector, so no per-VM `nodes` list is
  # authored in tfvars -- it's expanded here for the shared module.
  derived_nfs_client_mounts = flatten([
    for vm_name, vm in local.all_vms_map : [
      for m in vm.nfs_mounts : {
        nodes       = [vm_name]
        server      = m.server
        export_path = m.export_path
        mount_path  = m.mount_path
        options     = m.options
        read_only   = m.read_only
      }
    ]
  ])
}

# Render shared cloud-init user-data for all nodes
module "cloudinit" {
  source = "../shared/modules/cloudinit-renderer"

  cloud_init_selected     = var.cluster.cloud_init_selected
  node_username           = var.cluster.username
  timezone                = var.cluster.timezone
  extra_packages          = var.extra_packages
  public_key              = module.ssh_keys.public_key_openssh
  cluster_token           = module.ssh_keys.cluster_token
  k3s                     = var.k3s
  rke2                    = var.rke2
  ansible                 = var.ansible
  package_upgrade_enabled = var.cluster.package_upgrade_enabled
  nfs                     = { client = { mounts = local.derived_nfs_client_mounts } }

  vms = {
    for vm in concat(local.master_details, local.worker_details, local.vm_details) :
    vm.name => {
      hostname            = vm.name
      fqdn                = "${vm.name}.${local.subdomain}"
      domain              = local.subdomain
      node_role           = vm.role
      cloud_init_selected = vm.role == "vm" ? "default" : null
      is_first_master     = vm.name == local.first_master_name
      first_master_ip     = local.first_master_name != null ? azurerm_network_interface.vm-interface[local.first_master_name].private_ip_address : null
      current_private_ip  = azurerm_network_interface.vm-interface[vm.name].private_ip_address
      extra_disks         = try(local.vm_disks[vm.name], [])
      k3s_tls_sans = concat(var.k3s.tls_sans,
        compact([local.public_kube_api_endpoint]),
        [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )
      rke2_tls_sans = concat(var.rke2.tls_sans,
        compact([local.public_kube_api_endpoint]),
        [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
        [for master in local.master_details : "${master.name}.${local.subdomain}"]
      )
    }
  }
}

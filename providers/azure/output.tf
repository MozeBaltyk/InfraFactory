###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {
  content = templatefile("../shared/inventory/hosts.tpl", {
    controller_ips = [for vm in local.master_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
    worker_ips     = [for vm in local.worker_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
    vm_ips         = [for vm in local.vm_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
  })
  filename   = "${local.env_path}/hosts.ini"
  depends_on = [azurerm_public_ip.vm-pip]
}

###
### Display
###

output "cluster_nodes" {
  description = "Cluster node connection data"

  value = {
    controller_ips = [for vm in local.master_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
    worker_ips     = [for vm in local.worker_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
    vm_ips         = [for vm in local.vm_details : azurerm_public_ip.vm-pip[vm.name].ip_address]

    controllers = [for vm in local.master_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
    workers     = [for vm in local.worker_details : azurerm_public_ip.vm-pip[vm.name].ip_address]

    public_ips = concat(
      [for vm in local.master_details : azurerm_public_ip.vm-pip[vm.name].ip_address],
      [for vm in local.worker_details : azurerm_public_ip.vm-pip[vm.name].ip_address],
      [for vm in local.vm_details : azurerm_public_ip.vm-pip[vm.name].ip_address],
    )

    private_ips = {
      controllers = [for vm in local.master_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address]
      workers     = [for vm in local.worker_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address]
      vms         = [for vm in local.vm_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address]
      all = concat(
        [for vm in local.master_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address],
        [for vm in local.worker_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address],
        [for vm in local.vm_details : azurerm_network_interface.vm-interface[vm.name].private_ip_address],
      )
    }

    public_kube_api_endpoint = local.public_kube_api_endpoint
    ssh_first_master         = local.first_master_name != null ? "ssh -o StrictHostKeyChecking=no -i env/${var.infra_provider}/${terraform.workspace}/.key.private ${var.cluster.username}@${azurerm_public_ip.vm-pip[local.first_master_name].ip_address}" : null
  }
}

output "kubeconfig_command" {
  value = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) && local.first_master_name != null && var.infra.masters.user_data_enabled ? (<<-EOT
kubecm add -cf env/${var.infra_provider}/${terraform.workspace}/kubeconfig --context-name ${var.cluster.cloud_init_selected}-${var.infra_provider}-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/${var.infra_provider}/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
  ) : ""
}

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

    # Full §5 node objects: name/role/private/public/operator_address/bootstrap_endpoint.
    nodes = {
      for vm in concat(local.master_details, local.worker_details, local.vm_details) :
      vm.name => {
        name               = vm.name
        role               = vm.role
        private_ip         = azurerm_network_interface.vm-interface[vm.name].private_ip_address
        public_ip          = azurerm_public_ip.vm-pip[vm.name].ip_address
        operator_address   = azurerm_public_ip.vm-pip[vm.name].ip_address
        bootstrap_endpoint = azurerm_public_ip.vm-pip[vm.name].ip_address
      }
    }
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

###
### Contract endpoint outputs (§10)
###
output "kubernetes_endpoint" {
  description = "Stable Kubernetes API endpoint (first master public IP)."

  value = local.public_kube_api_endpoint
}

output "bootstrap_endpoints" {
  description = "Deterministic per-node access endpoints used during bootstrap (public IP per node)."

  value = {
    for vm in concat(local.master_details, local.worker_details, local.vm_details) :
    vm.name => azurerm_public_ip.vm-pip[vm.name].ip_address
  }
}

output "management_endpoint" {
  description = "Stable day-2 management endpoint. Azure does not run Talos: null."

  value = null
}

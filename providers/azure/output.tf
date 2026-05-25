###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {
  content = templatefile("../shared/inventory/hosts.tpl", {
    controller_ips = [for k, vm in local.masters_map : azurerm_public_ip.vm-pip[k].ip_address]
    worker_ips     = [for k, vm in local.workers_map : azurerm_public_ip.vm-pip[k].ip_address]
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
    controllers              = [for k, vm in local.masters_map : azurerm_public_ip.vm-pip[k].ip_address]
    workers                  = [for k, vm in local.workers_map : azurerm_public_ip.vm-pip[k].ip_address]
    public_kube_api_endpoint = local.public_kube_api_endpoint
    ssh_first_master         = "ssh -o StrictHostKeyChecking=no -i env/${var.infra_provider}/${terraform.workspace}/.key.private ${var.cluster.username}@${azurerm_public_ip.vm-pip[local.first_master_name].ip_address}"
  }
}

output "kubeconfig_command" {
  value = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? (<<-EOT
kubecm add -cf env/${var.infra_provider}/${terraform.workspace}/kubeconfig --context-name ${var.cluster.cloud_init_selected}-${var.infra_provider}-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/${var.infra_provider}/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
  ) : ""
}

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
### Import Kubeconfig
###
resource "null_resource" "fetch_kubeconfig" {
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? 1 : 0

  depends_on = [
    azurerm_linux_virtual_machine.vms
  ]

  triggers = {
    path                     = local.env_path
    ssh_endpoint             = azurerm_public_ip.vm-pip[local.first_master_name].ip_address
    public_kube_api_endpoint = local.public_kube_api_endpoint
  }

  provisioner "local-exec" {
    command = <<EOT
if [ "${var.cluster.cloud_init_selected}" = "rke2" ]; then
  KUBE_CONF_PATH="/etc/rancher/rke2/rke2.yaml"
elif [ "${var.cluster.cloud_init_selected}" = "k3s" ]; then
  KUBE_CONF_PATH="/etc/rancher/k3s/k3s.yaml"
else
  echo "No kubeconfig path defined for cloud_init_selected=${var.cluster.cloud_init_selected}"
  exit 0
fi

ssh -o StrictHostKeyChecking=no -i ${self.triggers.path}/.key.private \
${var.cluster.username}@${self.triggers.ssh_endpoint} \
"sudo cat $KUBE_CONF_PATH" | sed -E \
  -e "s#server: https://127\\.0\\.0\\.1:[0-9]+#server: https://${self.triggers.public_kube_api_endpoint}:6443#" \
> ${self.triggers.path}/kubeconfig
EOT
  }

  # Cleanup on destroy
  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ${self.triggers.path}/kubeconfig"
  }
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

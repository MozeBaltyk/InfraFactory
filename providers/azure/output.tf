###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {

  content = templatefile("../shared/inventory/hosts.tpl", {

    controller_ips = [
      for pip in azurerm_public_ip.controller-pip :
      pip.ip_address
    ]

    worker_ips = [
      for pip in azurerm_public_ip.worker-pip :
      pip.ip_address
    ]

  })

  filename = "${local.local_env_path}/hosts.ini"

  depends_on = [
    azurerm_linux_virtual_machine.masters,
    azurerm_linux_virtual_machine.workers
  ]
}

###
### Import Kubeconfig
###
resource "null_resource" "fetch_kubeconfig" {
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? 1 : 0

  depends_on = [
    azurerm_linux_virtual_machine.masters
  ]

  triggers = {
    path = local.local_env_path
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
${var.cluster.username}@${azurerm_public_ip.controller-pip[0].ip_address} \
"sudo cat $KUBE_CONF_PATH" | sed "s/127.0.0.1/${azurerm_public_ip.controller-pip[0].ip_address}/" \
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
  description = "Public IP addresses of cluster nodes"

  value = {
    controllers = [for pip in azurerm_public_ip.controller-pip : pip.ip_address]
    workers     = [for pip in azurerm_public_ip.worker-pip : pip.ip_address]
    ssh_first_master = "ssh -o StrictHostKeyChecking=no -i env/AZ/${terraform.workspace}/.key.private ${var.cluster.username}@${azurerm_public_ip.controller-pip[0].ip_address}"
  }
}

output "kubeconfig_command" {
  value = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? (<<-EOT
kubecm add -cf env/AZ/${terraform.workspace}/kubeconfig --context-name ${var.cluster.cloud_init_selected}-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/AZ/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
) : ""
}
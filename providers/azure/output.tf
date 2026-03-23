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

  depends_on = [
    azurerm_linux_virtual_machine.masters
  ]
  provisioner "local-exec" {
    command = <<EOT
ssh -o StrictHostKeyChecking=no -i ${local.local_env_path}/.key.private \
${var.cluster.username}@${azurerm_public_ip.controller-pip[0].ip_address} \
"sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/${azurerm_public_ip.controller-pip[0].ip_address}/" \
> ${local.local_env_path}/kubeconfig
EOT
  }
}


###
### Display
###

output "ip_address_controllers" {
  description = "Public IP addresses of controller nodes"
  value       = [for pip in azurerm_public_ip.controller-pip : pip.ip_address]
}

output "ip_address_workers" {
  description = "Public IP addresses of worker nodes"
  value       = [for pip in azurerm_public_ip.worker-pip : pip.ip_address]
}

output "kubeconfig_command" {
  value = var.cluster.cloud_init_selected == "k3s" ? (<<-EOT
kubecm add -cf env/AZ/${terraform.workspace}/kubeconfig --context-name k3s-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/AZ/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
) : ""
}
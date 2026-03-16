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
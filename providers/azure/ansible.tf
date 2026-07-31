###
### Ansible flow: cloud-init check, TLS SAN reconciliation and kubeconfig fetch
### (shared module)
###

module "ansible" {
  source = "../shared/modules/ansible-artifacts"

  env_path            = local.env_path
  cluster_id          = var.cluster.id
  username            = var.cluster.username
  cloud_init_selected = var.cluster.cloud_init_selected
  kube_api_endpoint   = local.public_kube_api_endpoint
  ssh_host            = azurerm_public_ip.vm-pip[local.first_master_name].ip_address

  controller_ips = [
    for k, vm in local.masters_map : azurerm_public_ip.vm-pip[k].ip_address
  ]
  worker_ips = [
    for k, vm in local.workers_map : azurerm_public_ip.vm-pip[k].ip_address
  ]

  depends_on = [
    azurerm_linux_virtual_machine.vms
  ]
}

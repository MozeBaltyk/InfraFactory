###
### Ansible flow: cloud-init check, TLS SAN reconciliation and kubeconfig fetch
### (shared module)
###

locals {
  k8s_master_user_data_enabled = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) && var.infra.masters.count > 0 && var.infra.masters.user_data_enabled
  k8s_cloudinit_check_enabled = (
    local.k8s_master_user_data_enabled &&
    (var.infra.workers.count == 0 || var.infra.workers.user_data_enabled)
  )
}

module "ansible" {
  source = "../shared/modules/ansible-artifacts"

  env_path            = local.env_path
  cluster_id          = var.cluster.id
  username            = var.cluster.username
  cloud_init_selected = var.cluster.cloud_init_selected
  kube_api_endpoint   = local.public_kube_api_endpoint
  ssh_host            = azurerm_public_ip.vm-pip[local.first_master_name].ip_address
  controller_ips      = [for vm in local.master_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
  worker_ips          = [for vm in local.worker_details : azurerm_public_ip.vm-pip[vm.name].ip_address]
  vm_ips              = [for vm in local.vm_details : azurerm_public_ip.vm-pip[vm.name].ip_address]

  cloudinit_check_enabled = local.k8s_cloudinit_check_enabled
  k8s_flow_enabled        = local.k8s_master_user_data_enabled

  depends_on = [
    azurerm_linux_virtual_machine.vms
  ]
}

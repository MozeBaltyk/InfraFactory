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
  ssh_host            = local.vm_public_ipv4_addresses[local.first_master_name]

  controller_ips = compact([
    for vm in local.master_details :
    local.vm_public_ipv4_addresses[vm.name]
  ])

  worker_ips = compact([
    for vm in local.worker_details :
    local.vm_public_ipv4_addresses[vm.name]
  ])

  vm_ips = compact([
    for vm in local.vm_details :
    local.vm_public_ipv4_addresses[vm.name]
  ])

  cloudinit_check_enabled = !local.is_talos && local.k8s_cloudinit_check_enabled
  k8s_flow_enabled        = !local.is_talos && local.k8s_master_user_data_enabled
  write_local_artifacts   = !local.is_talos

  depends_on = [
    ovh_cloud_project_instance.vms,
    data.ovh_cloud_project_instance.vms
  ]
}

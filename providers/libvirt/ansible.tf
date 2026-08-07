###
### Ansible flow: cloud-init check, TLS SAN reconciliation and kubeconfig fetch
### (shared module; skipped for Talos which has its own bootstrap)
###

locals {
  k8s_master_user_data_enabled = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) && var.infra.masters.count > 0 && var.infra.masters.user_data_enabled
  k8s_cloudinit_check_enabled = (
    local.k8s_master_user_data_enabled &&
    (var.infra.workers.count == 0 || var.infra.workers.user_data_enabled)
  )
}

module "ansible" {
  count  = local.is_talos ? 0 : 1
  source = "../shared/modules/ansible-artifacts"

  env_path            = local.env_path
  cluster_id          = var.cluster.id
  username            = var.cluster.username
  cloud_init_selected = var.cluster.cloud_init_selected
  kube_api_endpoint   = local.kube_api_endpoint
  ssh_host            = local.first_master_name != null ? local.vm_operator_endpoints[local.first_master_name] : null

  controller_ips = [
    for vm_name, vm in local.masters_map : local.vm_operator_endpoints[vm_name]
  ]
  worker_ips = [
    for vm_name, vm in local.workers_map : local.vm_operator_endpoints[vm_name]
  ]
  vm_ips = [
    for vm_name, vm in local.vms_map : local.vm_operator_endpoints[vm_name]
  ]

  write_local_artifacts = local.write_local_artifacts
  gitops_mode           = local.gitops_mode

  cloudinit_check_enabled = local.k8s_cloudinit_check_enabled
  k8s_flow_enabled        = local.k8s_master_user_data_enabled

  depends_on = [
    libvirt_domain.vms,
    null_resource.sleep_before_inventory,
    module.ssh_keys
  ]
}

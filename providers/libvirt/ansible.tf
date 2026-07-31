###
### Ansible flow: cloud-init check, TLS SAN reconciliation and kubeconfig fetch
### (shared module; skipped for Talos which has its own bootstrap)
###

module "ansible" {
  count  = local.is_talos ? 0 : 1
  source = "../shared/modules/ansible-artifacts"

  env_path            = local.env_path
  cluster_id          = var.cluster.id
  username            = var.cluster.username
  cloud_init_selected = var.cluster.cloud_init_selected
  kube_api_endpoint   = local.kube_api_endpoint
  ssh_host            = local.vm_operator_endpoints[local.first_master_name]

  controller_ips = [
    for vm_name, vm in local.masters_map : local.vm_operator_endpoints[vm_name]
  ]
  worker_ips = [
    for vm_name, vm in local.workers_map : local.vm_operator_endpoints[vm_name]
  ]

  write_local_artifacts = local.write_local_artifacts
  gitops_mode           = local.gitops_mode

  depends_on = [
    libvirt_domain.vms,
    null_resource.sleep_before_inventory,
    module.ssh_keys
  ]
}

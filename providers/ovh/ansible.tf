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
  ssh_host            = local.vm_public_ipv4_addresses[local.first_master_name]

  controller_ips = compact([
    for vm in local.master_details :
    local.vm_public_ipv4_addresses[vm.name]
  ])

  worker_ips = compact([
    for vm in local.worker_details :
    local.vm_public_ipv4_addresses[vm.name]
  ])

  depends_on = [
    ovh_cloud_project_instance.vms,
    data.ovh_cloud_project_instance.vms
  ]
}

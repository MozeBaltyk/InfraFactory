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
  source = "../../platform/artifacts/ansible-artifacts"

  env_path            = local.env_path
  cluster_id          = var.cluster.id
  username            = var.cluster.username
  cloud_init_selected = var.cluster.cloud_init_selected
  kube_api_endpoint   = local.public_kube_api_endpoint
  ssh_host            = local.lb_ssh_jump_enabled ? local.master_details[0].private_ip : local.vm_public_ipv4_addresses[local.first_master_name]

  controller_ips = compact([
    for vm in local.master_details :
    local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]
  ])

  worker_ips = compact([
    for vm in local.worker_details :
    local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]
  ])

  vm_ips = compact([
    for vm in local.vm_details :
    local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]
  ])

  # Self-contained ProxyCommand: the inner ssh must carry its own flags because
  # ProxyJump does not forward -i/-o to the jump connection (fresh bastion host
  # keys then fail strict verification without a tty).
  proxy_jump = local.lb_ssh_jump_enabled ? {
    common_args = "-o ProxyCommand='ssh -W %h:%p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${abspath("${local.env_path}/.key.private")} ${var.cluster.username}@${local.bastion_public_ipv4_address}'"
  } : null

  node_generation = {
    for name in keys(local.cluster_vms_map) :
    name => local.lb_ssh_jump_enabled ? ovh_cloud_project_instance.private_cluster[name].id : ovh_cloud_project_instance.vms[name].id
  }

  cloudinit_check_enabled = local.k8s_cloudinit_check_enabled
  k8s_flow_enabled        = local.k8s_master_user_data_enabled
  write_local_artifacts   = true

  depends_on = [
    ovh_cloud_project_instance.vms,
    ovh_cloud_project_instance.private_cluster,
    ovh_cloud_project_instance.bastion,
    data.ovh_cloud_project_instance.vms,
    openstack_networking_port_secgroup_associate_v2.cluster_public,
    openstack_networking_port_secgroup_associate_v2.cluster_private,
    openstack_networking_port_secgroup_associate_v2.bastion_public,
    openstack_networking_port_secgroup_associate_v2.bastion_private,
    ovh_cloud_project_loadbalancer.kube_api,
    terraform_data.bastion_cloudinit_ready,
  ]
}

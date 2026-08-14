###
### Display
###
output "cluster_nodes" {
  description = "Cluster node connection data"

  value = {
    controller_ips = [for vm in local.master_details : local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]]
    worker_ips     = [for vm in local.worker_details : local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]]
    vm_ips         = compact([for vm in local.vm_details : local.vm_public_ipv4_addresses[vm.name]])

    ssh_first_master = local.first_master_name != null ? try(
      local.lb_ssh_jump_enabled ? format(
        "ssh -F %s %s",
        jsonencode("env/${var.infra_provider}/${terraform.workspace}/ssh_config"),
        local.first_master_name,
        ) : format(
        "ssh -o StrictHostKeyChecking=no -i env/%s/%s/.key.private %s@%s",
        var.infra_provider,
        terraform.workspace,
        var.cluster.username,
        local.vm_public_ipv4_addresses[local.first_master_name],
      ),
      "waiting for IP assignment..."
    ) : null
  }

  depends_on = [ovh_cloud_project_instance.vms]
}

output "kube_api_load_balancer" {
  description = "Kubernetes API load balancer details (only when enabled)"

  value = local.lb_enabled ? {
    floating_ip = local.lb_floating_ip_address
    flavor      = var.network.kube_api.load_balancer.flavor
    pool_members = [
      for m in local.master_details : "${m.name} (${m.private_ip}:6443)"
    ]
  } : null
}

output "bastion" {
  description = "Dedicated OVH SSH bastion details (only when jump mode is enabled)"

  value = local.lb_ssh_jump_enabled ? {
    name       = local.bastion_name
    public_ip  = local.bastion_public_ipv4_address
    private_ip = local.bastion_private_ip
    flavor = {
      id    = local.bastion_flavor.id
      name  = local.bastion_flavor.name
      vcpus = local.bastion_flavor.vcpus
      ram   = local.bastion_flavor.ram
      disk  = local.bastion_flavor.disk
    }
    command = format(
      "ssh -F %s %s",
      jsonencode("env/${var.infra_provider}/${terraform.workspace}/ssh_config"),
      local.bastion_name,
    )
    cluster_private_ips = {
      controllers = [for vm in local.master_details : vm.private_ip]
      workers     = [for vm in local.worker_details : vm.private_ip]
    }
    first_master_command = format(
      "ssh -F %s %s",
      jsonencode("env/${var.infra_provider}/${terraform.workspace}/ssh_config"),
      local.first_master_name,
    )
  } : null
}

output "kubeconfig_command" {
  value = local.k8s_master_user_data_enabled ? (<<-EOT
kubecm add -cf env/${var.infra_provider}/${terraform.workspace}/kubeconfig --context-name ${var.cluster.cloud_init_selected}-${var.infra_provider}-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/${var.infra_provider}/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
  ) : ""
}

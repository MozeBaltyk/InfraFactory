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
        "ssh -i env/%s/%s/.key.private -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ProxyCommand='ssh -W %%h:%%p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s/.key.private %s@%s' %s@%s",
        var.infra_provider,
        terraform.workspace,
        local.env_path,
        var.cluster.username,
        local.bastion_public_ipv4_address,
        var.cluster.username,
        local.master_details[0].private_ip,
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
      "ssh -i env/%s/%s/.key.private -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes %s@%s",
      var.infra_provider,
      terraform.workspace,
      var.cluster.username,
      local.bastion_public_ipv4_address,
    )
    cluster_private_ips = {
      controllers = [for vm in local.master_details : vm.private_ip]
      workers     = [for vm in local.worker_details : vm.private_ip]
    }
    first_master_command = format(
      "ssh -i env/%s/%s/.key.private -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -o ProxyCommand='ssh -W %%h:%%p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i %s/.key.private %s@%s' %s@%s",
      var.infra_provider,
      terraform.workspace,
      local.env_path,
      var.cluster.username,
      local.bastion_public_ipv4_address,
      var.cluster.username,
      local.master_details[0].private_ip,
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

###
### Contract endpoint outputs (§10)
###
output "kubernetes_endpoint" {
  description = "Stable Kubernetes API endpoint (LB floating IP, DNS, or first master public/private IP)."

  value = local.public_kube_api_endpoint
}

output "bootstrap_endpoints" {
  description = "Deterministic per-node access endpoints used during bootstrap (private IP in jump mode, public IP otherwise)."

  value = {
    for vm in concat(local.master_details, local.worker_details, local.vm_details) :
    vm.name => local.lb_ssh_jump_enabled ? vm.private_ip : local.vm_public_ipv4_addresses[vm.name]
  }
}

output "management_endpoint" {
  description = "Stable day-2 management endpoint. OVH does not run Talos: null."

  value = null
}

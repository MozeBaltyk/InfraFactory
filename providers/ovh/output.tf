###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {

  content = templatefile("../shared/inventory/hosts.tpl", {

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
  })

  filename = "${local.env_path}/hosts.ini"

  depends_on = [
    ovh_cloud_project_instance.vms,
    terraform_data.validate_public_ips,
  ]
}

###
### Display
###
output "cluster_nodes" {
  description = "Cluster node connection data"

  value = {
    controller_ips = compact([for vm in local.master_details : local.vm_public_ipv4_addresses[vm.name]])
    worker_ips     = compact([for vm in local.worker_details : local.vm_public_ipv4_addresses[vm.name]])
    vm_ips         = compact([for vm in local.vm_details : local.vm_public_ipv4_addresses[vm.name]])
    public_ips = compact(concat(
      [for vm in local.master_details : local.vm_public_ipv4_addresses[vm.name]],
      [for vm in local.worker_details : local.vm_public_ipv4_addresses[vm.name]],
      [for vm in local.vm_details : local.vm_public_ipv4_addresses[vm.name]],
    ))
    private_ips = {
      controllers = [for vm in local.master_details : vm.private_ip]
      workers     = [for vm in local.worker_details : vm.private_ip]
      vms         = [for vm in local.vm_details : vm.private_ip]
      all         = [for vm in local.all_vms_map : vm.private_ip]
    }

    ssh_first_master = local.first_master_name != null ? try(
      format(
        "ssh -o StrictHostKeyChecking=no -i env/%s/%s/.key.private %s@%s",
        var.infra_provider,
        terraform.workspace,
        var.cluster.username,
        local.vm_public_ipv4_addresses[local.first_master_name]
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

output "master_ssh_jump" {
  description = "Optional SSH jump endpoint through the OVH kube-api load balancer (only when enabled)"

  value = local.lb_ssh_jump_enabled ? {
    endpoint      = local.lb_floating_ip_address
    port          = local.lb_ssh_jump_port
    target_master = "${local.master_details[0].name} (${local.master_details[0].private_ip}:22)"
    command = format(
      "ssh -o StrictHostKeyChecking=no -i env/%s/%s/.key.private -p %d %s@%s",
      var.infra_provider,
      terraform.workspace,
      local.lb_ssh_jump_port,
      var.cluster.username,
      local.lb_floating_ip_address
    )
    private_ips = {
      controllers = [for vm in local.master_details : vm.private_ip]
      workers     = [for vm in local.worker_details : vm.private_ip]
      vms         = [for vm in local.vm_details : vm.private_ip]
      all         = [for vm in local.all_vms_map : vm.private_ip]
    }
    example_vm_command = length(local.vm_details) > 0 ? format(
      "ssh -i env/%s/%s/.key.private -o StrictHostKeyChecking=no -o \"ProxyCommand=ssh -i env/%s/%s/.key.private -o StrictHostKeyChecking=no -p %d -W %%h:%%p %s@%s\" %s@%s",
      var.infra_provider,
      terraform.workspace,
      var.infra_provider,
      terraform.workspace,
      local.lb_ssh_jump_port,
      var.cluster.username,
      local.lb_floating_ip_address,
      var.cluster.username,
      local.vm_details[0].private_ip
    ) : null
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

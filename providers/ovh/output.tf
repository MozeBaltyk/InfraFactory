###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {

  content = templatefile("../shared/inventory/hosts.tpl", {

    controller_ips = [
      for vm in local.master_details :
      local.vm_public_ipv4_addresses[vm.name]
    ]

    worker_ips = [
      for vm in local.worker_details :
      local.vm_public_ipv4_addresses[vm.name]
    ]
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

    ssh_first_master = try(
      format(
        "ssh -o StrictHostKeyChecking=no -i env/%s/%s/.key.private %s@%s",
        var.infra_provider,
        terraform.workspace,
        var.cluster.username,
        local.vm_public_ipv4_addresses[local.first_master_name]
      ),
      "waiting for IP assignment..."
    )
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

output "kubeconfig_command" {
  value = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? (<<-EOT
kubecm add -cf env/${var.infra_provider}/${terraform.workspace}/kubeconfig --context-name ${var.cluster.cloud_init_selected}-${var.infra_provider}-${terraform.workspace} --create
# Or :
export KUBECONFIG=env/${var.infra_provider}/${terraform.workspace}/kubeconfig
# Then :
kubectl get nodes
EOT
  ) : ""
}

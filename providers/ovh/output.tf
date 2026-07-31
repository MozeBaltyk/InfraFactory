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

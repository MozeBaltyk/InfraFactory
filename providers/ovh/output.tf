resource "terraform_data" "validate_kube_api_dns" {
  lifecycle {
    precondition {
      condition = (
        local.kube_api_endpoint_mode != "dns" ||
        local.kube_api_dns_name != null
      )

      error_message = "network.kube_api.dns.name must be set when endpoint = \"dns\"."
    }
  }
}

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
  })

  filename = "${local.env_path}/hosts.ini"

  depends_on = [
    ovh_cloud_project_instance.vms
  ]
}

###
### Import Kubeconfig
###
resource "null_resource" "fetch_kubeconfig" {
  count = (
    contains(["k3s", "rke2"], var.cluster.cloud_init_selected)
    &&
    local.vm_public_ipv4_addresses[local.first_master_name] != null
  ) ? 1 : 0

  triggers = {
    path = local.env_path
    ssh_endpoint = local.vm_public_ipv4_addresses[local.first_master_name]
    public_kube_api_endpoint = local.public_kube_api_endpoint
    cloud_init_selected = var.cluster.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
if [ "${var.cluster.cloud_init_selected}" = "rke2" ]; then
  KUBE_CONF_PATH="/etc/rancher/rke2/rke2.yaml"
elif [ "${var.cluster.cloud_init_selected}" = "k3s" ]; then
  KUBE_CONF_PATH="/etc/rancher/k3s/k3s.yaml"
else
  echo "No kubeconfig path defined"
  exit 0
fi

ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -i ${self.triggers.path}/.key.private \
  ${var.cluster.username}@${self.triggers.ssh_endpoint} \
  "sudo cat $KUBE_CONF_PATH" | sed -E \
  -e "s#server: https://127\\.0\\.0\\.1:[0-9]+#server: https://${self.triggers.public_kube_api_endpoint}:6443#" \
  > ${self.triggers.path}/kubeconfig
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ${self.triggers.path}/kubeconfig"
  }

  depends_on = [
    null_resource.bootstrap_nodes
  ]
}

###
### Display
###
output "cluster_nodes" {
  description = "Cluster node connection data"

  value = {
    controller_ips = [ for vm in local.master_details : local.vm_public_ipv4_addresses[vm.name] ]
    worker_ips = [ for vm in local.worker_details : local.vm_public_ipv4_addresses[vm.name] ]

    ssh_first_master = format(
      "ssh -o StrictHostKeyChecking=no -i env/%s/%s/.key.private %s@%s",
      var.infra_provider,
      terraform.workspace,
      var.cluster.username,
      local.vm_public_ipv4_addresses[local.first_master_name]
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

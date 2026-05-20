###
### Generate the hosts.ini file
###
resource "local_file" "ansible_inventory" {
  content = templatefile("../shared/inventory/hosts.tpl", {
    controller_ips = local.master_public_ips
    worker_ips     = local.worker_public_ips
  })
  filename = "${local.env_path}/hosts.ini"

  depends_on = [
    ovh_cloud_project_instance.masters,
    ovh_cloud_project_instance.workers,
    ovh_cloud_project_loadbalancer.kube_api,
    null_resource.reconcile_kube_api_tls_sans,
  ]
}

###
### Import Kubeconfig
###
resource "null_resource" "fetch_kubeconfig" {
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? 1 : 0

  depends_on = [
    null_resource.wait_for_master_cloud_init,
    null_resource.wait_for_worker_cloud_init,
    null_resource.reconcile_kube_api_tls_sans,
  ]

  triggers = {
    path                     = local.env_path
    ssh_endpoint             = local.ssh_endpoint
    public_kube_api_endpoint = local.public_kube_api_endpoint
    cloud_init_selected      = var.cluster.cloud_init_selected
    tls_sans_reconciled      = try(null_resource.reconcile_kube_api_tls_sans[0].id, "")
  }

  provisioner "local-exec" {
    command = <<EOT
if [ "${var.cluster.cloud_init_selected}" = "rke2" ]; then
  KUBE_CONF_PATH="/etc/rancher/rke2/rke2.yaml"
elif [ "${var.cluster.cloud_init_selected}" = "k3s" ]; then
  KUBE_CONF_PATH="/etc/rancher/k3s/k3s.yaml"
else
  echo "No kubeconfig path defined for cloud_init_selected=${var.cluster.cloud_init_selected}"
  exit 0
fi

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i ${self.triggers.path}/.key.private \
${var.cluster.username}@${local.ssh_endpoint} \
"sudo cat $KUBE_CONF_PATH" | sed -E \
  -e "s#server: https://127\\.0\\.0\\.1:[0-9]+#server: https://${local.public_kube_api_endpoint}:6443#" \
> ${self.triggers.path}/kubeconfig
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -f ${self.triggers.path}/kubeconfig"
  }
}

resource "null_resource" "reconcile_kube_api_tls_sans" {
  count = local.kube_api_tls_san_reconcile_enabled ? 1 : 0

  depends_on = [
    null_resource.wait_for_master_cloud_init,
    null_resource.wait_for_worker_cloud_init,
    ovh_cloud_project_loadbalancer.kube_api,
  ]

  triggers = {
    path                     = local.env_path
    master_endpoints         = join(" ", local.master_public_ips)
    public_kube_api_endpoint = local.public_kube_api_endpoint
    cloud_init_selected      = var.cluster.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
ssh_opts='-T -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3'
per_master_timeout='180'
recovery_delay='10'

for ssh_endpoint in ${self.triggers.master_endpoints}; do
timeout --foreground "$per_master_timeout" \
ssh $ssh_opts -i ${self.triggers.path}/.key.private \
${var.cluster.username}@$ssh_endpoint \
"sudo /usr/local/bin/reconcile-${self.triggers.cloud_init_selected}-kube-api-tls-san.sh '${self.triggers.public_kube_api_endpoint}'"

sleep "$recovery_delay"
done
EOT
  }
}

###
### Display
###
output "cluster_nodes" {
  description = "Cluster node connection data"

  value = {
    controllers           = local.master_public_ips
    workers               = local.worker_public_ips
    private_controllers   = local.master_private_ips
    private_workers       = local.worker_private_ips
    cluster_join_endpoint = local.cluster_join_endpoint
    ssh_first_master      = "ssh -o StrictHostKeyChecking=no -i env/${var.infra_provider}/${terraform.workspace}/.key.private ${var.cluster.username}@${local.ssh_endpoint}"
  }
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

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
  ]

  triggers = {
    path                     = local.env_path
    ssh_endpoint             = local.ssh_endpoint
    public_kube_api_endpoint = local.public_kube_api_endpoint
    cloud_init_selected      = var.cluster.cloud_init_selected
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
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) && local.kube_api_lb_enabled && local.kube_api_endpoint_mode == "lb_ip" ? 1 : 0

  depends_on = [
    null_resource.wait_for_master_cloud_init,
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
ssh_opts='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3'
per_master_timeout='180'
recovery_delay='10'

for ssh_endpoint in ${self.triggers.master_endpoints}; do
timeout --foreground "$per_master_timeout" \
ssh $ssh_opts -i ${self.triggers.path}/.key.private \
${var.cluster.username}@$ssh_endpoint <<'REMOTE'
set -eu

endpoint='${self.triggers.public_kube_api_endpoint}'
mode='${self.triggers.cloud_init_selected}'

case "$mode" in
  rke2)
    config_path='/etc/rancher/rke2/config.yaml'
    service_name='rke2-server'
    cert_dir='/var/lib/rancher/rke2/server/tls'
    ;;
  k3s)
    config_path='/etc/rancher/k3s/config.yaml'
    service_name='k3s'
    cert_dir='/var/lib/rancher/k3s/server/tls'
    ;;
  *)
    exit 0
    ;;
esac

if sudo grep -Fqx "  - $endpoint" "$config_path"; then
  exit 0
fi

tmp_file="$(mktemp)"
sudo awk -v endpoint="$endpoint" '
  BEGIN {
    in_tls_san = 0
    inserted = 0
  }

  function insert_endpoint() {
    if (!inserted) {
      print "  - " endpoint
      inserted = 1
    }
  }

  {
    if ($0 == "tls-san:") {
      in_tls_san = 1
      print $0
      next
    }

    if (in_tls_san && $0 ~ /^  - /) {
      print $0
      next
    }

    if (in_tls_san) {
      insert_endpoint()
      in_tls_san = 0
    }

    print $0
  }

  END {
    if (in_tls_san) {
      insert_endpoint()
    }
  }
' "$config_path" > "$tmp_file"

sudo mv "$tmp_file" "$config_path"
sudo systemctl stop "$service_name"
sudo rm -f "$cert_dir/serving-kube-apiserver.crt" "$cert_dir/serving-kube-apiserver.key"
sudo systemctl start "$service_name"

deadline="$(($(date +%s) + 120))"
while true; do
  if sudo systemctl is-active --quiet "$service_name" && sudo ss -H -lnt '( sport = :6443 )' | grep -q ':6443'; then
    break
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Timed out waiting for $service_name readiness on $(hostname)" >&2
    sudo systemctl status "$service_name" --no-pager || true
    sudo ss -H -lnt '( sport = :6443 )' || true
    exit 1
  fi

  sleep 2
done
REMOTE

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

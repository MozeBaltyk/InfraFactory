## LB locals
locals {
  kube_api_lb_enabled = try(
    var.network.kube_api.load_balancer.enabled,
    false
  )

  kube_api_lb_flavor_name = try(
    var.network.kube_api.load_balancer.flavor,
    null
  )

  kube_api_gateway_name = format(
    "%s-%s-gateway",
    var.cluster.id,
    terraform.workspace
  )

  kube_api_lb_name = format(
    "%s-%s-kube-api",
    var.cluster.id,
    terraform.workspace
  )

  kube_api_lb_flavor = (
    local.kube_api_lb_enabled
    ? try(
        one([
          for flavor in data.ovh_cloud_project_loadbalancer_flavors.kube_api[0].flavors :
          flavor
          if local.kube_api_lb_flavor_name == null || flavor.name == local.kube_api_lb_flavor_name
        ]),
        null
      )
    : null
  )

  kube_api_tls_san_reconcile_enabled = (
    local.kube_api_lb_enabled &&
    contains(["k3s", "rke2"], var.cluster.cloud_init_selected)
  )

  kube_api_endpoint_mode = try(
    var.network.kube_api.endpoint,
    "lb_ip"
  )

  kube_api_dns_name = try(
    var.network.kube_api.dns.name,
    null
  )

  kube_api_lb_public_ip = try(
    ovh_cloud_project_loadbalancer.kube_api[0].vip_address,
    null
  )

  kube_api_bootstrap_endpoint = local.master_details[0].private_ip

  public_kube_api_endpoint = (
    local.kube_api_lb_enabled
    ? (
        local.kube_api_endpoint_mode == "dns"
        ? local.kube_api_dns_name
        : local.kube_api_lb_public_ip
      )
    : local.kube_api_bootstrap_endpoint
  )
}

data "ovh_cloud_project_loadbalancer_flavors" "kube_api" {
  count = local.kube_api_lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
}

resource "ovh_cloud_project_gateway" "kube_api" {
  count = local.kube_api_lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name         = local.kube_api_gateway_name
  model        = "s"
  network_id   = local.private_network_id
  subnet_id    = local.private_subnet_id
}

resource "ovh_cloud_project_loadbalancer" "kube_api" {
  count = local.kube_api_lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
  name         = local.kube_api_lb_name
  flavor_id    = local.kube_api_lb_flavor.id

  lifecycle {
    precondition {
      condition     = local.kube_api_lb_flavor != null
      error_message = try(var.network.load_balancer_flavor, null) != null ? "OVH load balancer flavor '${var.network.load_balancer_flavor}' is not available in region '${var.cluster.region}'." : "No OVH load balancer flavor is available in region '${var.cluster.region}'."
    }
  }

  network = {
    private = {
      network = {
        id        = local.private_network_id
        subnet_id = local.private_subnet_id
      }
      gateway = {
        id = ovh_cloud_project_gateway.kube_api[0].id
      }
      floating_ip_create = {
        description = local.kube_api_lb_name
      }
    }
  }

  listeners = [{
    name     = "kube-api"
    protocol = "tcp"
    port     = 6443
    pool = {
      name      = "kube-api"
      protocol  = "tcp"
      algorithm = "roundRobin"
      health_monitor = {
        name             = "kube-api"
        monitor_type     = "tcp"
        delay            = 5
        timeout          = 3
        max_retries      = 3
        max_retries_down = 3
      }
    members = [
        for idx, vm in local.master_details : {
            address       = vm.private_ip
            protocol_port = 6443
            name          = vm.name
            weight        = 1
        }
        if vm.private_ip != null
    ]
    }
  }]

  depends_on = [
    ovh_cloud_project_instance.vms,
    ovh_cloud_project_gateway.kube_api
  ]
}

## Fetch kubeconfig from the first master and rewrite the server endpoint to use the LB floating IP or VIP
resource "null_resource" "reconcile_kube_api_tls_sans" {
  count = local.kube_api_tls_san_reconcile_enabled ? 1 : 0

  triggers = {
    path                     = local.env_path
    master_endpoints         = join(" ", [for vm in local.master_details : local.vm_public_ipv4_addresses[vm.name]])
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
"sudo /usr/local/bin/reconcile-kube-api-tls-san.sh '${self.triggers.public_kube_api_endpoint}'"

sleep "$recovery_delay"
done
EOT
  }

  depends_on = [
    ovh_cloud_project_instance.vms,
    ovh_cloud_project_loadbalancer.kube_api,
  ]
}
data "ovh_cloud_project_loadbalancer_flavors" "kube_api" {
  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
}

resource "ovh_cloud_project_network_private" "cluster" {
  count = local.private_network_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  name         = local.private_network_name
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  count = local.private_network_enabled ? 1 : 0

  service_name                    = var.ovh_project_service_name
  network_id                      = ovh_cloud_project_network_private.cluster[0].regions_openstack_ids[var.cluster.region]
  region                          = var.cluster.region
  name                            = local.private_subnet_name
  cidr                            = var.network.cidr
  dhcp                            = true
  enable_gateway_ip               = true
  use_default_public_dns_resolver = true
}

resource "null_resource" "private_network_destroy_grace" {
  count = local.private_network_enabled ? 1 : 0

  triggers = {
    network_id   = local.private_network_id
    subnet_id    = local.private_subnet_id
    wait_seconds = "20"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "sleep ${self.triggers.wait_seconds}"
  }

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

resource "ovh_cloud_project_gateway" "kube_api" {
  count = local.kube_api_lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name         = local.kube_api_gateway_name
  model        = "s"
  network_id   = local.private_network_id
  subnet_id    = local.private_subnet_id

  depends_on = [
    null_resource.private_network_destroy_grace,
  ]
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
        for idx, ip in local.master_private_ips : {
          address       = ip
          protocol_port = 6443
          name          = format("master-%02d", idx + 1)
          weight        = 1
        }
        if ip != null
      ]
    }
  }]

  depends_on = [
    null_resource.private_network_destroy_grace,
    ovh_cloud_project_instance.masters,
    ovh_cloud_project_gateway.kube_api,
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

locals {
  private_network_enabled = try(var.network.cidr, null) != null
  private_network_id      = try(ovh_cloud_project_network_private.cluster[0].regions_openstack_ids[var.cluster.region], null)
  private_subnet_id       = try(ovh_cloud_project_network_private_subnet_v2.cluster[0].id, null)
  kube_api_lb_enabled     = local.private_network_enabled
  kube_api_endpoint_mode  = try(var.network.kube_api_endpoint_mode, "lb_ip")
  kube_api_dns_name       = try(var.network.kube_api_dns_name, null)
  kube_api_lb_flavors_by_name = {
    for flavor in data.ovh_cloud_project_loadbalancer_flavors.kube_api.flavors : flavor.name => flavor
    if try(var.network.load_balancer_flavor, null) == null || flavor.name == var.network.load_balancer_flavor
  }
  kube_api_lb_flavor_name     = try(sort(keys(local.kube_api_lb_flavors_by_name))[0], null)
  kube_api_lb_flavor          = local.kube_api_lb_flavor_name != null ? local.kube_api_lb_flavors_by_name[local.kube_api_lb_flavor_name] : null
  kube_api_gateway_name       = "${var.cluster.id}-${terraform.workspace}-kube-api-gateway"
  kube_api_lb_name            = "${var.cluster.id}-${terraform.workspace}-kube-api"
  kube_api_bootstrap_endpoint = local.kube_api_endpoint_mode == "dns" ? local.kube_api_dns_name : null

  private_ip_host_offset_base = local.private_network_enabled ? (tonumber(split("/", var.network.cidr)[1]) <= 28 ? 10 : 2) : null

  node_private_ip_map = local.private_network_enabled ? {
    for idx, vm in concat(local.master_details, local.worker_details) :
    vm.name => cidrhost(var.network.cidr, local.private_ip_host_offset_base + idx)
  } : {}

  master_private_ip_map = {
    for vm in local.master_details : vm.name => try(local.node_private_ip_map[vm.name], null)
  }

  worker_private_ip_map = {
    for vm in local.worker_details : vm.name => try(local.node_private_ip_map[vm.name], null)
  }

  master_public_ip_map = {
    for vm in local.master_details : vm.name => (
      local.private_network_enabled
      ? one([
        for addr in ovh_cloud_project_instance.masters[vm.name].addresses : addr.ip
        if addr.version == 4 && addr.ip != local.master_private_ip_map[vm.name]
      ])
      : one([
        for addr in ovh_cloud_project_instance.masters[vm.name].addresses : addr.ip
        if addr.version == 4
      ])
    )
  }

  worker_public_ip_map = {
    for vm in local.worker_details : vm.name => (
      local.private_network_enabled
      ? one([
        for addr in ovh_cloud_project_instance.workers[vm.name].addresses : addr.ip
        if addr.version == 4 && addr.ip != local.worker_private_ip_map[vm.name]
      ])
      : one([
        for addr in ovh_cloud_project_instance.workers[vm.name].addresses : addr.ip
        if addr.version == 4
      ])
    )
  }

  master_public_ips = [
    for vm in local.master_details : local.master_public_ip_map[vm.name]
  ]

  master_private_ips = [
    for vm in local.master_details : try(local.master_private_ip_map[vm.name], null)
  ]

  worker_public_ips = [
    for vm in local.worker_details : local.worker_public_ip_map[vm.name]
  ]

  worker_private_ips = [
    for vm in local.worker_details : try(local.worker_private_ip_map[vm.name], null)
  ]

  first_master_public_ip  = try(local.master_public_ips[0], null)
  first_master_private_ip = try(local.master_private_ips[0], null)

  # Keep SSH and inventory on public IPs, but reserve cluster_join_endpoint for the private join path.
  ssh_endpoint          = local.first_master_public_ip
  cluster_join_endpoint = local.first_master_private_ip
  public_kube_api_endpoint = local.kube_api_lb_enabled ? coalesce(
    local.kube_api_bootstrap_endpoint,
    try(ovh_cloud_project_loadbalancer.kube_api[0].floating_ip.ip, null),
    try(ovh_cloud_project_loadbalancer.kube_api[0].vip_address, null),
    local.first_master_public_ip,
  ) : coalesce(local.kube_api_bootstrap_endpoint, local.first_master_public_ip)
}

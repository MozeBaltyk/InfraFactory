###
### Private Network and Subnet
###

resource "ovh_cloud_project_network_private" "cluster" {
  count = local.private_network_managed ? 1 : 0

  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  vlan_id      = var.network.private.vlan_id
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  count = local.private_network_managed ? 1 : 0

  service_name = var.ovh_project_service_name
  network_id   = ovh_cloud_project_network_private.cluster[0].regions_openstack_ids[var.cluster.region]
  region       = var.cluster.region
  name         = format("%s-subnet", var.cluster.id)
  cidr         = local.private_cidr
  # Gateway is mandatory for lb with public floating IP (but not for private-only network).
  enable_gateway_ip               = local.lb_enabled
  use_default_public_dns_resolver = false
  # Private VM ports and guest netplan use deterministic static private IPs.
  dhcp = true
}

data "ovh_cloud_project_network_privates" "existing" {
  count = local.private_network_existing ? 1 : 0

  service_name = var.ovh_project_service_name
}

data "ovh_cloud_project_network_private_subnets" "existing" {
  count = local.private_network_existing && local.existing_private_network_global_id != null ? 1 : 0

  service_name = var.ovh_project_service_name
  network_id   = local.existing_private_network_global_id
}

resource "terraform_data" "validate_existing_private_network" {
  count = local.private_network_existing ? 1 : 0

  input = {
    vlan_id       = var.network.private.vlan_id
    cidr          = local.private_cidr
    region        = var.cluster.region
    network_count = length(local.existing_private_network_matches)
    subnet_count  = length(local.existing_private_subnet_matches)
  }

  lifecycle {
    precondition {
      condition     = length(local.existing_private_network_matches) == 1
      error_message = "network.private.mode = \"existing\" requires exactly one OVH private network matching network.private.vlan_id in cluster.region."
    }

    precondition {
      condition     = length(local.existing_private_subnet_matches) == 1
      error_message = "network.private.mode = \"existing\" requires exactly one OVH private subnet matching network.private.cidr on the discovered private network."
    }
  }
}

###
### Cluster-owned OpenStack security group
###

resource "openstack_networking_secgroup_v2" "cluster" {
  count       = local.kubernetes_enabled ? 1 : 0
  name        = "${var.cluster.id}-${terraform.workspace}"
  description = "InfraFactory ${var.cluster.id} cluster"
  region      = var.cluster.region

  depends_on = [terraform_data.validate_operator_ingress_cidrs]
}

locals {
  cluster_public_ingress_rules = local.kubernetes_enabled ? merge(
    {
      for cidr in local.kube_api_ingress_cidrs : "kube-api-${cidr}" => {
        port = 6443
        cidr = cidr
      }
    },
    local.is_talos ? {
      for cidr in local.kube_api_ingress_cidrs : "talos-api-${cidr}" => {
        port = 50000
        cidr = cidr
      }
      } : {
      for cidr in local.kube_api_ingress_cidrs : "ssh-${cidr}" => {
        port = 22
        cidr = cidr
      }
    }
  ) : {}
}

resource "openstack_networking_secgroup_rule_v2" "cluster_public_ingress" {
  for_each = local.cluster_public_ingress_rules

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = each.value.cidr
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

resource "openstack_networking_secgroup_rule_v2" "cluster_private_ingress" {
  count = local.kubernetes_enabled ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = local.private_cidr
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

data "openstack_networking_port_v2" "cluster_public" {
  for_each = local.kubernetes_enabled ? local.cluster_vms_map : {}

  device_id = ovh_cloud_project_instance.vms[each.key].id
  fixed_ip  = local.vm_public_ipv4_addresses_after_wait[each.key]
  region    = var.cluster.region

  depends_on = [terraform_data.validate_public_ips]
}

data "openstack_networking_port_v2" "cluster_private" {
  for_each = local.kubernetes_enabled ? local.cluster_vms_map : {}

  device_id  = ovh_cloud_project_instance.vms[each.key].id
  network_id = local.private_network_id
  fixed_ip   = each.value.private_ip
  region     = var.cluster.region
}

resource "openstack_networking_port_secgroup_associate_v2" "cluster_public" {
  for_each = local.kubernetes_enabled ? local.cluster_vms_map : {}

  port_id            = data.openstack_networking_port_v2.cluster_public[each.key].id
  security_group_ids = [openstack_networking_secgroup_v2.cluster[0].id]
  enforce            = true
  region             = var.cluster.region
}

resource "openstack_networking_port_secgroup_associate_v2" "cluster_private" {
  for_each = local.kubernetes_enabled ? local.cluster_vms_map : {}

  port_id            = data.openstack_networking_port_v2.cluster_private[each.key].id
  security_group_ids = [openstack_networking_secgroup_v2.cluster[0].id]
  enforce            = true
  region             = var.cluster.region
}

###
### Gateway and floating IP for the Kubernetes API load balancer
###

resource "terraform_data" "gateway_vm_generation" {
  count = local.lb_enabled ? 1 : 0

  input = {
    for name, vm in ovh_cloud_project_instance.vms : name => vm.id
  }
}

resource "ovh_cloud_gateway" "kube_api" {
  count = local.lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name         = "${var.cluster.id}-gateway"

  external_gateway = {
    enabled = true
    model   = upper(var.network.kube_api.load_balancer.gateway_model)
  }

  subnet_ids = [local.private_subnet_id]

  lifecycle {
    replace_triggered_by = [terraform_data.gateway_vm_generation[count.index]]
  }

  depends_on = [ovh_cloud_project_instance.vms]
}

resource "ovh_cloud_floating_ip" "kube_api" {
  count = local.lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  description  = "${var.cluster.id}-kube-api-fip"
}

###
### Load Balancer for the Kubernetes API
###

data "ovh_cloud_project_loadbalancer_flavors" "lb" {
  count        = local.lb_enabled ? 1 : 0
  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
}

resource "ovh_cloud_project_loadbalancer" "kube_api" {
  count = local.lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
  name         = "${var.cluster.id}-kube-api"
  flavor_id    = local.lb_flavor_id

  network = {
    private = {
      network = {
        id        = local.private_network_id
        subnet_id = local.private_subnet_id
      }
      gateway = {
        id = ovh_cloud_gateway.kube_api[0].id
      }
      floating_ip = {
        id = ovh_cloud_floating_ip.kube_api[0].current_state.id
      }
    }
  }

  listeners = concat(
    [
      {
        port          = 6443
        protocol      = "tcp"
        name          = "kube-api"
        allowed_cidrs = local.kube_api_ingress_cidrs

        pool = {
          algorithm = "roundRobin"
          protocol  = "tcp"
          name      = "kube-api-pool"

          health_monitor = {
            name         = "${var.cluster.id}-kube-api-hm"
            delay        = 5
            max_retries  = 3
            timeout      = 3
            monitor_type = "tcp"
          }

          members = [
            for m in local.master_details : {
              address       = m.private_ip
              protocol_port = 6443
              weight        = 1
            }
          ]
        }
      }
    ],
    local.lb_ssh_jump_enabled ? [
      {
        port          = local.lb_ssh_jump_port
        protocol      = "tcp"
        name          = "master-ssh-jump"
        allowed_cidrs = local.kube_api_ingress_cidrs

        pool = {
          algorithm = "roundRobin"
          protocol  = "tcp"
          name      = "master-ssh-jump-pool"

          health_monitor = {
            name         = "${var.cluster.id}-master-ssh-jump-hm"
            delay        = 5
            max_retries  = 3
            timeout      = 3
            monitor_type = "tcp"
          }

          members = [
            {
              address       = local.master_details[0].private_ip
              protocol_port = 22
              weight        = 1
            }
          ]
        }
      }
    ] : []
  )

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
    ovh_cloud_project_instance.vms,
    openstack_networking_port_secgroup_associate_v2.cluster_private,
  ]
}

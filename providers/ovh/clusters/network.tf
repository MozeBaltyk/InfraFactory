###
### Private Network and Subnet
###

# OVH public network, used as the first NIC on public-attached instances
# (DHCP-assigned public IPv4) and to identify the public fixed IP in state.
data "openstack_networking_network_v2" "ext_net" {
  name   = "Ext-Net"
  region = var.cluster.region
}

resource "ovh_cloud_project_network_private" "cluster" {
  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  vlan_id      = var.network.private.vlan_id
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  service_name = var.ovh_project_service_name
  network_id   = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  region       = var.cluster.region
  name         = format("%s-subnet", var.cluster.id)
  cidr         = local.private_cidr
  # Gateway is mandatory for lb with public floating IP (but not for private-only network).
  enable_gateway_ip               = local.lb_enabled
  use_default_public_dns_resolver = false
  # DHCP stays OFF: guests use static netplan (use_dhcp = false everywhere)
  # and first-boot user_data arrives via Nova config-drive, so the Neutron
  # DHCP namespace's 169.254.169.254 metadata proxy is no longer needed.
  # No DHCP agent ports also means no orphan ports blocking subnet
  # deletion (409) on destroy.
  dhcp = false
}

###
### Cluster-owned OpenStack security group
###

resource "openstack_networking_secgroup_v2" "cluster" {
  count                = local.kubernetes_enabled ? 1 : 0
  name                 = "${var.cluster.id}-${terraform.workspace}"
  description          = "InfraFactory ${var.cluster.id} cluster"
  region               = var.cluster.region
  delete_default_rules = local.k8s_nodes

  depends_on = [terraform_data.validate_operator_ingress_cidrs]
}

resource "openstack_networking_secgroup_rule_v2" "cluster_ssh_from_bastion" {
  count = local.k8s_nodes ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "${local.bastion_private_ip}/32"
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

locals {
  jump_cluster_east_west_rules = local.k8s_nodes ? {
    tcp-low  = { protocol = "tcp", min = 1, max = 21 }
    tcp-high = { protocol = "tcp", min = 23, max = 65535 }
    udp      = { protocol = "udp", min = 1, max = 65535 }
    icmp     = { protocol = "icmp", min = null, max = null }
  } : {}
}

resource "openstack_networking_secgroup_rule_v2" "cluster_east_west" {
  for_each = local.jump_cluster_east_west_rules

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = each.value.protocol
  port_range_min    = each.value.min
  port_range_max    = each.value.max
  remote_group_id   = openstack_networking_secgroup_v2.cluster[0].id
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

resource "openstack_networking_secgroup_rule_v2" "cluster_lb_backend" {
  count = local.lb_enabled ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 6443
  port_range_max    = 6443
  remote_ip_prefix  = local.private_cidr
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

# Workload ingress (80/443) backend reachability: the LB's http/https
# listeners target the ingress-controller host ports on the masters, so
# those ports must also be reachable from the LB's amphora subnet —
# cluster_lb_backend above opens only 6443. TLS terminates at the ingress
# controller, never at Octavia. Ports follow the same overridable inputs
# the LB members use.
resource "openstack_networking_secgroup_rule_v2" "cluster_lb_ingress_backend" {
  for_each = local.lb_enabled ? {
    http  = var.network.kube_api.load_balancer.ingress_http_port
    https = var.network.kube_api.load_balancer.ingress_https_port
  } : {}

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value
  port_range_max    = each.value
  remote_ip_prefix  = local.private_cidr
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

resource "openstack_networking_secgroup_rule_v2" "cluster_egress" {
  count             = local.k8s_nodes ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.cluster[0].id
  region            = var.cluster.region
}

data "openstack_networking_port_v2" "cluster_private" {
  for_each = local.kubernetes_enabled ? local.cluster_vms_map : {}

  device_id  = openstack_compute_instance_v2.vms[each.key].id
  network_id = local.private_network_id
  fixed_ip   = each.value.private_ip
  region     = var.cluster.region
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
### The gateway is created BEFORE the VMs (the VMs depend on it — see main.tf):
### private-only nodes need working egress at first boot for apt/rke2, and the
### gateway resource only returns once it is READY. It is subnet-scoped NAT —
### it has no dependency on the VM set, so no replace trigger is needed.
###

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

  listeners = [
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
    },
    # Workload ingress as L4 passthrough (TLS terminates at the ingress
    # controller, never at Octavia). Backend ports default to the stock
    # k3s traefik+servicelb host ports; override per distro as needed.
    {
      port          = 80
      protocol      = "tcp"
      name          = "http-ingress"
      allowed_cidrs = local.lb_ingress_cidrs

      pool = {
        algorithm = "roundRobin"
        protocol  = "tcp"
        name      = "http-ingress-pool"

        health_monitor = {
          name         = "${var.cluster.id}-http-ingress-hm"
          delay        = 5
          max_retries  = 3
          timeout      = 3
          monitor_type = "tcp"
        }

        members = [
          for m in local.master_details : {
            address       = m.private_ip
            protocol_port = var.network.kube_api.load_balancer.ingress_http_port
            weight        = 1
          }
        ]
      }
    },
    {
      port          = 443
      protocol      = "tcp"
      name          = "https-ingress"
      allowed_cidrs = local.lb_ingress_cidrs

      pool = {
        algorithm = "roundRobin"
        protocol  = "tcp"
        name      = "https-ingress-pool"

        health_monitor = {
          name         = "${var.cluster.id}-https-ingress-hm"
          delay        = 5
          max_retries  = 3
          timeout      = 3
          monitor_type = "tcp"
        }

        members = [
          for m in local.master_details : {
            address       = m.private_ip
            protocol_port = var.network.kube_api.load_balancer.ingress_https_port
            weight        = 1
          }
        ]
      }
    },
  ]

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
    openstack_compute_instance_v2.vms,
    openstack_networking_port_secgroup_associate_v2.cluster_private,
  ]
}

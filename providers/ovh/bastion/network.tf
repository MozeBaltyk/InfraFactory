###
### Public network (first NIC on the bastion, DHCP-assigned public IPv4)
###

data "openstack_networking_network_v2" "ext_net" {
  name   = "Ext-Net"
  region = var.bastion.region
}

###
### Served cluster networks: looked up, never owned. Each cluster workspace
### owns its private network; the bastion only discovers it by (vlan_id, cidr)
### and attaches a port with the shared reserved bastion IP. The network must
### therefore exist before the attach apply (bastion-first workflow, step 2-3).
###

data "ovh_cloud_project_network_privates" "all" {
  service_name = var.ovh_project_service_name
}

locals {
  cluster_network_matches = {
    for name, c in var.clusters : name => [
      for network in data.ovh_cloud_project_network_privates.all.networks : network
      if network.vlan_id == c.vlan_id && length([
        for region in network.regions : region
        if region.region == var.bastion.region
      ]) == 1
    ]
  }

  cluster_network_global_ids = {
    for name, matches in local.cluster_network_matches :
    name => try(matches[0].id, null)
  }

  cluster_private_network_ids = {
    for name, matches in local.cluster_network_matches : name => try(one([
      for region in matches[0].regions : region.openstack_id
      if region.region == var.bastion.region
    ]), null)
  }
}

data "ovh_cloud_project_network_private_subnets" "clusters" {
  for_each = {
    for name, id in local.cluster_network_global_ids : name => id
    if id != null
  }

  service_name = var.ovh_project_service_name
  network_id   = each.value
}

locals {
  cluster_subnet_matches = {
    for name, c in var.clusters : name => [
      for subnet in try(data.ovh_cloud_project_network_private_subnets.clusters[name].subnets, []) : subnet
      if subnet.cidr == c.cidr
    ]
  }
}

resource "terraform_data" "validate_cluster_networks" {
  for_each = var.clusters

  input = {
    cluster       = each.key
    vlan_id       = each.value.vlan_id
    cidr          = each.value.cidr
    network_count = length(local.cluster_network_matches[each.key])
    subnet_count  = length(local.cluster_subnet_matches[each.key])
  }

  lifecycle {
    precondition {
      condition     = length(local.cluster_network_matches[each.key]) == 1
      error_message = "Cluster '${each.key}' requires exactly one OVH private network matching vlan_id ${each.value.vlan_id} in region '${var.bastion.region}'. Deploy the cluster network first (bastion-first workflow, step 2)."
    }

    precondition {
      condition     = length(local.cluster_subnet_matches[each.key]) == 1
      error_message = "Cluster '${each.key}' requires exactly one OVH private subnet matching cidr '${each.value.cidr}' on the discovered private network."
    }
  }
}

###
### Bastion security group: SSH in from explicit CIDRs + the operator's
### current IP (auto-detected, never a substitute for an explicit entry).
###

data "http" "my_ip" {
  url = "http://ifconfig.me/ip"
}

locals {
  my_public_ip = "${chomp(trimspace(data.http.my_ip.response_body))}/32"

  ingress_cidrs = distinct(concat(
    var.ingress_cidrs,
    [local.my_public_ip],
  ))
}

resource "openstack_networking_secgroup_v2" "bastion" {
  name                 = "${var.bastion.id}-sg"
  description          = "InfraFactory ${var.bastion.id} SSH bastion"
  region               = var.bastion.region
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each = toset(local.ingress_cidrs)

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion.id
  region            = var.bastion.region
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress" {
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.bastion.id
  region            = var.bastion.region
}

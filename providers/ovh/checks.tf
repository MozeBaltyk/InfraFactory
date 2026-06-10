check "ovh_multi_master_requires_private_network" {
  assert {
    condition = (
      var.infra.masters.count <= 1 ||
      try(trimspace(var.network.private.cidr), "") != ""
    )

    error_message = "network.private.cidr must be set when infra.masters.count is greater than 1 so OVH multi-master can use the private-network path."
  }
}

check "ovh_lb_requires_private_network" {
  assert {
    condition = (
      !local.kubernetes_enabled ||
      !local.lb_enabled ||
      try(trimspace(var.network.private.cidr), "") != ""
    )
    error_message = "network.private.cidr must be set when network.kube_api.load_balancer.enabled is true so the load balancer can attach to the private subnet."
  }
}

check "ovh_lb_flavor_exists" {
  assert {
    condition = (
      !local.kubernetes_enabled ||
      !local.lb_enabled ||
      local.lb_flavor_id != null
    )
    error_message = "Load balancer flavor '${var.network.kube_api.load_balancer.flavor}' was not found in region '${var.cluster.region}'."
  }
}

check "ovh_private_network_cidr_has_enough_addresses" {
  assert {
    condition = (
      try(trimspace(var.network.private.cidr), "") == "" ||
      can(
        cidrhost(
          var.network.private.cidr,
          (tonumber(split("/", var.network.private.cidr)[1]) <= 28 ? 10 : 2) + var.infra.masters.count + var.infra.workers.count + var.infra.vms.count - 1
        )
      )
    )

    error_message = "network.private.cidr must provide enough private IP addresses for all OVH VMs."
  }
}

check "ovh_existing_private_network_has_single_match" {
  assert {
    condition = (
      !local.private_network_existing ||
      length(local.existing_private_network_matches) == 1
    )

    error_message = "network.private.mode = \"existing\" requires exactly one OVH private network matching network.private.vlan_id in cluster.region."
  }
}

check "ovh_existing_private_subnet_has_single_match" {
  assert {
    condition = (
      !local.private_network_existing ||
      length(local.existing_private_subnet_matches) == 1
    )

    error_message = "network.private.mode = \"existing\" requires exactly one OVH private subnet matching network.private.cidr on the discovered private network."
  }
}

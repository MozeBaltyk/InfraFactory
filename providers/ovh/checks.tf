check "ovh_multi_master_requires_private_network" {
  assert {
    condition = (
      var.infra.masters.count <= 1 ||
      try(trimspace(var.network.private_cidr), "") != ""
    )

    error_message = "network.private_cidr must be set when infra.masters.count is greater than 1 so OVH multi-master can use the private-network path."
  }
}

check "ovh_private_network_cidr_has_enough_addresses" {
  assert {
    condition = (
      try(trimspace(var.network.private_cidr), "") == "" ||
      can(
        cidrhost(
          var.network.private_cidr,
          (tonumber(split("/", var.network.private_cidr)[1]) <= 28 ? 10 : 2) + var.infra.masters.count + var.infra.workers.count - 1
        )
      )
    )

    error_message = "network.private_cidr must provide enough private IP addresses for all OVH masters and workers."
  }
}

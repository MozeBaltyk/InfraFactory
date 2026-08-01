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

check "ovh_existing_private_network_vm_only" {
  assert {
    condition = (
      var.network.private.mode != "existing" ||
      (
        !local.kubernetes_enabled &&
        var.infra.masters.count == 0 &&
        var.infra.workers.count == 0 &&
        var.infra.vms.count > 0
      )
    )
    error_message = "network.private.mode = \"existing\" is only supported for VM-only deployments: cloud_init_selected = \"default\", masters.count = 0, workers.count = 0, and vms.count > 0."
  }
}

check "ovh_existing_private_network_ips_per_vm" {
  assert {
    condition = (
      var.network.private.mode != "existing" ||
      length(var.infra.vms.ip_addresses) == var.infra.vms.count
    )
    error_message = "network.private.mode = \"existing\" requires infra.vms.ip_addresses to contain exactly one static private IP per VM."
  }
}

check "ovh_existing_private_network_ips_unique" {
  assert {
    condition = (
      var.network.private.mode != "existing" ||
      length(distinct(var.infra.vms.ip_addresses)) == length(var.infra.vms.ip_addresses)
    )
    error_message = "infra.vms.ip_addresses must be unique."
  }
}

check "ovh_existing_private_network_ips_valid" {
  assert {
    condition = (
      var.network.private.mode != "existing" ||
      alltrue([
        for ip in var.infra.vms.ip_addresses :
        can(cidrnetmask("${ip}/32"))
      ])
    )
    error_message = "infra.vms.ip_addresses must contain valid IPv4 addresses."
  }
}

check "ovh_existing_private_network_no_lb" {
  assert {
    condition = (
      var.network.private.mode != "existing" ||
      !try(var.network.kube_api.load_balancer.enabled, false)
    )
    error_message = "network.private.mode = \"existing\" cannot create or manage a kube-api load balancer."
  }
}

check "ovh_lb_ip_endpoint_requires_lb" {
  assert {
    condition = (
      !local.kubernetes_enabled ||
      try(var.network.kube_api.endpoint, "public_ip") != "lb_ip" ||
      try(var.network.kube_api.load_balancer.enabled, false)
    )
    error_message = "network.kube_api.endpoint = \"lb_ip\" requires network.kube_api.load_balancer.enabled = true. Use endpoint = \"public_ip\" for minimal no-LB deployments."
  }
}

check "ovh_dns_endpoint_requires_name" {
  assert {
    condition = (
      !local.kubernetes_enabled ||
      try(var.network.kube_api.endpoint, "public_ip") != "dns" ||
      try(trimspace(var.network.kube_api.dns.name), "") != ""
    )
    error_message = "network.kube_api.endpoint = \"dns\" requires network.kube_api.dns.name to be set."
  }
}

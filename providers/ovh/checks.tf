check "ovh_multi_master_requires_private_network" {
  assert {
    condition = (
      var.infra.masters.count <= 1 ||
      try(trimspace(var.network.private.cidr), "") != ""
    )

    error_message = "network.private.cidr must be set when infra.masters.count is greater than 1 so OVH multi-master can use the private-network path."
  }
}

check "ovh_private_only_vms_require_gateway" {
  assert {
    condition = (
      local.private_gateway_ip != null ||
      length([
        for name, vm in local.all_vms_map : name
        if vm.private_attach && !vm.public_attach
      ]) == 0
    )
    error_message = "Private-only OVH VMs (no public interface) require a subnet gateway IP for egress: with a managed private network, enable network.kube_api.load_balancer so the gateway is created."
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

check "workspace_identifier" {
  assert {
    condition     = can(regex("^[A-Za-z0-9._-]+$", terraform.workspace))
    error_message = "The OVH workspace name must contain only A-Za-z0-9._-."
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
          (tonumber(split("/", var.network.private.cidr)[1]) <= 28 ? 10 : 2) + var.infra.masters.count + var.infra.workers.count + var.infra.vms.count + (local.lb_ssh_jump_enabled ? 1 : 0) - 1
        )
      )
    )

    error_message = "network.private.cidr must provide enough private IP addresses for all OVH VMs."
  }
}

check "ovh_reserved_bastion_ip_clear_of_nodes" {
  assert {
    condition = (
      try(trimspace(var.network.private.cidr), "") == "" ||
      module.ipam.last_node_hostnum < module.ipam.bastion_hostnum
    )

    error_message = "OVH node allocation (masters + workers + vms from the host offset base) reaches the reserved bastion IP (last usable host of network.private.cidr): widen the CIDR or reduce node counts."
  }
}

check "ovh_vlan_id_range" {
  assert {
    condition = (
      var.network.private.vlan_id >= 0 && var.network.private.vlan_id <= 4000
    )
    error_message = "network.private.vlan_id must be between 0 and 4000."
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

resource "terraform_data" "validate_operator_ingress_cidrs" {
  lifecycle {
    precondition {
      # Checks the explicit var, not local.kube_api_ingress_cidrs: that local
      # also carries the auto-detected caller IP (see local.my_public_ip),
      # which must never substitute for an explicit entry here.
      condition     = !local.kubernetes_enabled || length(try(var.network.kube_api.ingress_cidrs, [])) > 0
      error_message = "Kubernetes deployments require at least one explicit network.kube_api.ingress_cidrs entry (normally your operator/VPN public CIDR, for example 203.0.113.10/32). The unsafe 0.0.0.0/0 default is intentionally disabled. Your current public IP is added automatically in addition to this list."
    }
  }
}

###
### Storage
###

check "storage_nfs_required_fields" {
  assert {
    condition = alltrue([
      for key, s in local.storage_nfs_raw :
      try(trimspace(s.name), "") != "" && try(s.size, null) != null
    ])
    error_message = "storage.NFS[*] requires name and size (GB) to be set."
  }
}

check "storage_nfs_type_supported" {
  assert {
    condition = alltrue([
      for key, s in local.storage_nfs : s.type == "STANDARD_1AZ"
    ])
    error_message = "storage.NFS[*].type only supports \"STANDARD_1AZ\" today."
  }
}

check "storage_nfs_allowed_cidr_valid" {
  assert {
    condition = alltrue([
      for key, s in local.storage_nfs : can(cidrhost(s.allowed_cidr, 0))
    ])
    error_message = "storage.NFS[*].allowed_cidr must be a valid CIDR such as 10.0.0.0/24."
  }
}

check "storage_object_storage_required_fields" {
  assert {
    condition = alltrue([
      for key, b in local.storage_buckets_raw :
      try(trimspace(b.name), "") != "" && try(trimspace(b.region), "") != ""
    ])
    error_message = "storage.\"Object-storage\"[*] requires name and region to be set."
  }
}

check "storage_object_storage_bucket_names_unique" {
  assert {
    condition     = length(distinct([for key, b in local.storage_buckets : b.name])) == length(local.storage_buckets)
    error_message = "storage.\"Object-storage\"[*].name must be unique across keys (bucket names must be globally unique per region anyway)."
  }
}

check "storage_object_storage_region_prefix" {
  assert {
    condition = alltrue([
      for key, b in local.storage_buckets_raw : contains(["GRA", "SBG", "BHS"], b.region)
    ])
    error_message = "storage.\"Object-storage\"[*].region must be a region prefix: GRA, SBG, or BHS (not a full region name like GRA9)."
  }
}

check "storage_object_storage_versioning_valid" {
  assert {
    condition = alltrue([
      for key, b in local.storage_buckets_raw : contains(["enabled", "disabled", "suspended"], try(b.versioning, "disabled"))
    ])
    error_message = "storage.\"Object-storage\"[*].versioning must be one of: enabled, disabled, suspended."
  }
}

check "storage_object_storage_encryption_valid" {
  assert {
    condition = alltrue([
      for key, b in local.storage_buckets_raw :
      try(b.encryption.sse_algorithm, "AES256") == "AES256"
    ])
    error_message = "storage.\"Object-storage\"[*].encryption.sse_algorithm only supports \"AES256\" today."
  }
}

###
### infra.masters/workers/vms storage attachments
###

check "infra_nfs_attachments_exist" {
  assert {
    condition = alltrue(concat(
      [for key in try(var.infra.masters.nfs, []) : contains(keys(local.storage_nfs), key)],
      [for key in try(var.infra.workers.nfs, []) : contains(keys(local.storage_nfs), key)],
      [for key in try(var.infra.vms.nfs, []) : contains(keys(local.storage_nfs), key)],
    ))
    error_message = "infra.masters/workers/vms.nfs may only reference keys defined in storage.NFS: ${join(", ", keys(local.storage_nfs))}."
  }
}

check "infra_object_storage_attachments_exist" {
  assert {
    condition = alltrue(concat(
      [for key in try(var.infra.masters.object_storage, []) : contains(keys(local.storage_buckets), key)],
      [for key in try(var.infra.workers.object_storage, []) : contains(keys(local.storage_buckets), key)],
      [for key in try(var.infra.vms.object_storage, []) : contains(keys(local.storage_buckets), key)],
    ))
    error_message = "infra.masters/workers/vms.object_storage may only reference keys defined in storage.\"Object-storage\": ${join(", ", keys(local.storage_buckets))}."
  }
}

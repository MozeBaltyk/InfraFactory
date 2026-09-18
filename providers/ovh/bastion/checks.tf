check "bastion_ingress_cidrs_explicit" {
  assert {
    condition     = length(var.ingress_cidrs) > 0
    error_message = "Bastion requires at least one explicit ingress_cidrs entry (operator/VPN public CIDR). The auto-detected caller IP is added on top but never substitutes for an explicit entry."
  }
}

check "bastion_cluster_cidrs_valid" {
  assert {
    condition = alltrue([
      for name, c in var.clusters :
      can(cidrhost(c.cidr, 0)) && !strcontains(c.cidr, ":")
    ])
    error_message = "clusters[*].cidr must contain valid IPv4 CIDR blocks."
  }
}

check "bastion_cluster_vlan_id_range" {
  assert {
    condition = alltrue([
      for name, c in var.clusters :
      c.vlan_id >= 0 && c.vlan_id <= 4000
    ])
    error_message = "clusters[*].vlan_id must be between 0 and 4000."
  }
}

check "bastion_cluster_counts_match_ipam" {
  assert {
    condition = alltrue([
      for name in local.cluster_names_sorted :
      module.ipam[name].last_node_hostnum < module.ipam[name].bastion_hostnum
    ])
    error_message = "A served cluster's node allocation (masters + workers from the host offset base) reaches the reserved bastion IP: widen its CIDR or reduce counts."
  }
}

# Deterministic private IP plan shared by every consumer of a CIDR.
#
# Nodes allocate upwards from host_offset_base (masters, then workers, then
# managed extra VMs — the historical cidrhost contract). The bastion address
# is reserved at the top instead: last usable host of the prefix, so both the
# bastion stack and every cluster stack agree on it with no shared state.
locals {
  prefix = tonumber(split("/", var.cidr)[1])

  # Shared convention, single copy: short prefixes waste the low range
  # (gateway, LB VIPs), long prefixes start at the first usable hosts.
  host_offset_base = coalesce(var.host_offset_base, local.prefix <= 28 ? 10 : 2)

  total_hosts = pow(2, 32 - local.prefix)

  # Last usable host: broadcast is total_hosts - 1.
  bastion_hostnum = local.total_hosts - 2

  master_ips = [
    for i in range(var.masters_count) :
    cidrhost(var.cidr, local.host_offset_base + i)
  ]

  worker_ips = [
    for i in range(var.workers_count) :
    cidrhost(var.cidr, local.host_offset_base + var.masters_count + i)
  ]

  vm_ips = [
    for i in range(var.vms_count) :
    cidrhost(var.cidr, local.host_offset_base + var.masters_count + var.workers_count + i)
  ]

  node_count = var.masters_count + var.workers_count + var.vms_count

  # Highest host number handed to a node; host_offset_base - 1 when empty.
  last_node_hostnum = local.host_offset_base + local.node_count - 1

  bastion_ip = cidrhost(var.cidr, local.bastion_hostnum)
}

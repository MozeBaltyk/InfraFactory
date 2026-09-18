###
### Deterministic private IP plan (shared module)
###
### Single source of truth for the historical cidrhost contract: masters from
### the host offset base, then workers, then managed extra VMs. Values are
### byte-identical to the previous inline math, so only the source moved.
###
### Phase 0 of the bastion split: the embedded bastion keeps its legacy
### base+counts address until Phase 3 removes it; the new bastion module
### (Phase 1+) consumes module.ipam.bastion_ip (last usable host of the CIDR).
###

module "ipam" {
  source = "../shared/modules/ipam"

  cidr             = local.private_cidr
  host_offset_base = local.private_ip_host_offset_base
  masters_count    = var.infra.masters.count
  workers_count    = var.infra.workers.count
  vms_count        = var.infra.vms.count
}

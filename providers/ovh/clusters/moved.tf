# Preserve existing K3s/RKE2 state after removing count from these resources.
# Without these moves, OpenTofu would recreate the SSH key and token resources
# under their plain (uncounted) addresses.
moved {
  from = module.ssh_keys[0]
  to   = module.ssh_keys
}

moved {
  from = random_id.ssh_key_suffix[0]
  to   = random_id.ssh_key_suffix
}

# Single-resource merge (no moved block possible here: moved from/to must
# be static addresses, but node names are dynamic per workspace).
# Normal-mode workspaces need nothing (everything already lived in `vms`
# under identical keys). Jump-mode workspaces: before the first apply of
# this version, move each master/worker in state, e.g.
#   tofu state mv 'openstack_compute_instance_v2.private_cluster["ID-node01"]' 'openstack_compute_instance_v2.vms["ID-node01"]'
# Without the moves, plan destroys + recreates those nodes (same names and
# IPs, but a disruptive rebuild of masters/workers).

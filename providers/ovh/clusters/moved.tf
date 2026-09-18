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

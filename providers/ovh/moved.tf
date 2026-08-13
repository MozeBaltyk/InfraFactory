moved {
  from = module.ssh_keys
  to   = module.ssh_keys[0]
}

moved {
  from = random_id.ssh_key_suffix
  to   = random_id.ssh_key_suffix[0]
}

moved {
  from = ovh_cloud_project_ssh_key.cluster
  to   = ovh_cloud_project_ssh_key.cluster[0]
}

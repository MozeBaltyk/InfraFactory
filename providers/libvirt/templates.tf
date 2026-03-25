# Use CloudInit ISO to add SSH key to the instances
resource "libvirt_cloudinit_disk" "commoninit" {
  for_each = { for vm in concat(local.master_details, local.worker_details) : vm.name => vm }

  name = "${each.value.name}-commoninit.iso"

  user_data = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
    {
      os_name       = local.os.os_name
      hostname      = each.value.name
      fqdn          = "${each.value.name}.${local.subdomain}"
      domain        = local.subdomain

      clusterid     = var.cluster.id
      timezone      = var.cluster.timezone
      node_username = var.cluster.username

      public_key    = tls_private_key.global_key.public_key_openssh

      is_first_master   = each.value.name == local.master_details[0].name
      first_master_ip   = coalesce(local.master_details[0].ip, local.master_details[0].name)
      first_master_fqdn = "${local.master_details[0].name}.${local.subdomain}"

      node_role = each.value.role

      # K3s config
      k3s_token                  = var.k3s.token
      k3s_version                = var.k3s.version
      k3s_etcd_enabled           = var.k3s.etcd_enabled
      k3s_traefik_enabled        = var.k3s.traefik_enabled
      k3s_servicelb_enabled      = var.k3s.servicelb_enabled
      k3s_local_storage_enabled  = var.k3s.local_storage_enabled
      k3s_metrics_server_enabled = var.k3s.metrics_server_enabled

      # Optional Ansible
      ansible_pull_repo     = try(var.ansible.pull.repo, null)
      ansible_pull_branch   = try(var.ansible.pull.branch, "main")
      ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
      ansible_pull_timer    = try(var.ansible.pull.timer, null)
    }
  )

  network_config = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config_${var.network.ip_type}.cfg",
    {
      network_gateway = local.network_gateway
      domain          = local.subdomain
      dns_servers     = local.dns_servers
      ip_address      = each.value.ip
    }
  )

  meta_data = ""

  pool = libvirt_pool.factory_pool.name

}

# Generate environment-specific ansible.cfg
resource "local_file" "ansible_config" {
  filename = "${local.local_env_path}/ansible.cfg"
  content = <<-EOT
[defaults]
remote_user = ${var.cluster.username}
inventory =  ./hosts.ini
roles_path = ../../../ansible/roles
host_key_checking = false
display_skipped_hosts = false
deprecation_warnings = false
force_color       = True
stdout_callback   = yaml
private_key_file = ./.key.private
EOT

  depends_on = [null_resource.env_directory]
}
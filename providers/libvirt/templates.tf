# Use CloudInit ISO to add SSH key to the instances
resource "libvirt_cloudinit_disk" "commoninit" {

  for_each = {
    for vm in concat(local.master_details, local.worker_details) :
    vm.name => vm
  }

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
    }
  )

  network_config = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config_${var.network.ip_type}.cfg",
    {
      domain      = local.subdomain
      dns_servers = "${local.network_gateway},8.8.8.8"
    }
  )

  meta_data = ""

  pool = libvirt_pool.factory_pool.name
}
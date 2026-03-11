# Use CloudInit ISO to add SSH key to the instances
resource "libvirt_cloudinit_disk" "commoninit" {
  for_each = { for vm in concat(local.master_details, local.worker_details) : vm.name => vm }
  name           = "${each.value.name}-commoninit.iso"
  user_data      = templatefile("${path.module}/../shared/cloud-init/${var.which_cloud_init}/cloud_init.cfg.tftpl", {
    os_name           =   local.os_name,
    hostname          =   each.value.name
    fqdn              =   "${each.value.name}.${local.subdomain}"
    domain            =   local.subdomain
    clusterid         =   var.clusterid
    timezone          =   var.timezone
    public_key        =   tls_private_key.global_key.public_key_openssh
    k3s_token         =   var.k3s_token
    is_first_master   =   each.value.name == local.master_details[0].name
    first_master_fqdn =   "${local.master_details[0].name}.${local.subdomain}"
    node_role         =   each.value.role
    node_username     =   var.node_username
    k3s_version       = var.k3s_version
  })
  network_config = templatefile("${path.module}/../shared/cloud-init/${var.which_cloud_init}/network_config_${var.ip_type}.cfg", {})
  meta_data     = ""
  pool   = libvirt_pool.factory_pool.name
}

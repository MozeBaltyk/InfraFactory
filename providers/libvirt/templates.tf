# Use CloudInit ISO to add SSH key to the instances
resource "libvirt_cloudinit_disk" "commoninit" {
  for_each = { for vm in concat(local.master_details, local.worker_details) : vm.name => vm }
  name           = "${each.value.name}-commoninit.iso"
  user_data      = templatefile("${path.module}/../shared/cloud-init/${local.cloud_init_version}/cloud_init.cfg.tftpl", {
    os_name        =   local.os_name,
    hostname       =   each.value.name
    fqdn           =   "${each.value.name}.${local.subdomain}"
    domain         =   local.subdomain
    clusterid      =   var.clusterid
    timezone       =   var.timezone
    master_details =   indent(8, yamlencode(local.master_details))
    worker_details =   indent(8, yamlencode(local.worker_details))
    public_key     =   tls_private_key.global_key.public_key_openssh
  })
  network_config = templatefile("${path.module}/../shared/cloud-init/${local.cloud_init_version}/network_config_${var.ip_type}.cfg", {})
  meta_data     = ""
}

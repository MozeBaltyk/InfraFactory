# Use CloudInit ISO to add SSH key to the instances (skipped for Talos: nodes boot to maintenance mode)
module "cloudinit" {
  source = "../shared/modules/cloudinit-renderer"

  cloud_init_selected = var.cluster.cloud_init_selected
  node_username       = var.cluster.username
  timezone            = var.cluster.timezone
  extra_packages      = var.extra_packages
  public_key          = module.ssh_keys.public_key_openssh
  cluster_token       = module.ssh_keys.cluster_token
  k3s                 = var.k3s
  rke2                = var.rke2
  ansible             = var.ansible

  vms = local.is_talos ? {} : {
    for name, vm in local.all_vms_map :
    name => {
      hostname           = vm.name
      fqdn               = local.vm_fqdns[name]
      domain             = local.subdomain
      node_role          = vm.role
      is_first_master    = name == local.first_master_name
      first_master_ip    = local.first_master_ip
      current_private_ip = null
      extra_disks        = local.vm_disks[vm.name]
      k3s_tls_sans       = concat(var.k3s.tls_sans, [for master in local.master_details : local.vm_fqdns[master.name]])
      rke2_tls_sans      = concat(var.rke2.tls_sans, [for master in local.master_details : local.vm_fqdns[master.name]])
    }
  }
}

resource "libvirt_cloudinit_disk" "commoninit" {
  for_each = local.is_talos ? {} : local.all_vms_map

  name = "${each.value.name}-commoninit.iso"

  user_data = module.cloudinit.rendered[each.value.name]

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

  lifecycle {
    ignore_changes = []
  }
}

###
### Generate the ansible.cfg + hosts.ini files and run the ansible flow
### (see ansible.tf for the module call)
###

# Output the rendered ansible.cfg content in gitops mode, otherwise null
output "gitops_ansible_cfg" {
  description = "GitOps-mode rendered ansible.cfg content."
  value       = try(module.ansible[0].gitops_ansible_cfg, null)
}

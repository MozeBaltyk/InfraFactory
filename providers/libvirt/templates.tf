# Use CloudInit ISO to add SSH key to the instances (skipped for Talos: nodes boot to maintenance mode)
module "cloudinit" {
  source = "../../platform/cloud-init"

  cloud_init_selected = var.cluster.cloud_init_selected
  node_username       = var.cluster.username
  timezone            = var.cluster.timezone
  extra_packages      = var.extra_packages
  public_key          = module.ssh_keys.public_key_openssh
  cluster_token       = module.ssh_keys.cluster_token
  k3s                 = var.k3s
  rke2                = var.rke2
  ansible             = var.ansible
  package_upgrade_enabled = var.cluster.package_upgrade_enabled

  vms = local.is_talos ? {} : {
    for name, vm in local.all_vms_map :
    name => {
      hostname           = vm.name
      fqdn               = local.vm_fqdns[name]
      domain             = local.subdomain
      node_role          = vm.role
      cloud_init_selected = vm.role == "vm" ? "default" : null
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

  user_data = each.value.user_data_enabled ? module.cloudinit.rendered[each.value.name] : null

  network_config = templatefile(
    "${path.module}/../../platform/cloud-init/${each.value.role == "vm" ? "default" : var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
    {
      # Primary NIC on Libvirt cloud images
      interface_id         = "primary"
      interface_match_name = "ens3"
      interface_optional   = false

      # Libvirt drives DHCP vs static via var.network.ip_type
      use_dhcp   = var.network.ip_type == "dhcp"
      ip_address = each.value.ip
      # cidr_prefix is only used by the template when use_dhcp = false (static mode).
      # In DHCP mode the template skips it, but OpenTofu still evaluates the
      # expression eagerly. Guard against null cidr (valid for bridge mode).
      cidr_prefix = var.network.cidr != null ? split("/", var.network.cidr)[1] : null

      # In DHCP mode the server already supplies routes and DNS;
      # nameservers are still injected explicitly below for parity with the
      # previous behavior.
      accept_dhcp_routes = true
      accept_dhcp_dns    = true

      # Static-only: explicit default route. Suppressed in DHCP mode so the
      # rendered netplan matches the previous network_config_dhcp.cfg output.
      network_gateway = var.network.ip_type == "static" ? local.network_gateway : null

      dns_servers       = local.dns_servers
      domain            = local.subdomain
      emit_empty_routes = false
    }
  )

  meta_data = ""

  pool = libvirt_pool.factory_pool.name

  depends_on = [libvirt_volume.os_image]

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

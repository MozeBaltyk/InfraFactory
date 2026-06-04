# Use CloudInit ISO to add SSH key to the instances
resource "libvirt_cloudinit_disk" "commoninit" {
  for_each = local.all_vms_map

  name = "${each.value.name}-commoninit.iso"

  user_data = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
    {
      os_name  = local.os.os_name
      hostname = each.value.name
      fqdn     = local.vm_fqdns[each.key]
      domain   = local.subdomain

      extra_disks    = local.vm_disks[each.value.name]
      extra_packages = var.extra_packages

      clusterid     = var.cluster.id
      timezone      = var.cluster.timezone
      node_username = var.cluster.username

      package_upgrade_enabled = var.cluster.package_upgrade_enabled

      public_key = tls_private_key.global_key.public_key_openssh

      is_first_master        = each.value.name == local.first_master_name
      first_master_ip        = local.first_master_ip
      first_master_fqdn      = local.first_master_fqdn
      current_private_ip     = null
      prefer_private_node_ip = false

      node_role = each.value.role

      # Optional K3s config
      k3s_token                  = local.cluster_token
      k3s_version                = var.k3s.version
      k3s_tls_sans               = concat(var.k3s.tls_sans, [for master in local.master_details : local.vm_fqdns[master.name]])
      k3s_etcd_enabled           = var.k3s.etcd_enabled
      k3s_traefik_enabled        = var.k3s.traefik_enabled
      k3s_servicelb_enabled      = var.k3s.servicelb_enabled
      k3s_local_storage_enabled  = var.k3s.local_storage_enabled
      k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
      k3s_flannel_enabled        = var.k3s.flannel_enabled

      # Optional RKE2 config
      rke2_token                    = local.cluster_token
      rke2_version                  = var.rke2.version
      rke2_tls_sans                 = concat(var.rke2.tls_sans, [for master in local.master_details : local.vm_fqdns[master.name]])
      rke2_etcd_enabled             = var.rke2.etcd_enabled
      rke2_ingress_nginx_enabled    = var.rke2.ingress_nginx_enabled
      rke2_metrics_server_enabled   = var.rke2.metrics_server_enabled
      rke2_cni                      = var.rke2.cni
      rke2_ingress_type             = var.rke2.ingress_type
      rke2_kube_proxy_enabled       = try(var.rke2.kube_proxy_enabled, true)
      rke2_cilium_hubble_enabled    = try(var.rke2.cilium.hubble_enabled, false)
      rke2_cilium_operator_replicas = try(var.rke2.cilium.operator_replicas, 1)

      # Optional Ansible
      ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
      ansible_pull_branch   = try(var.ansible.pull.branch, "main")
      ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
      ansible_pull_token    = try(var.ansible.pull.token, null)
      ansible_pull_timer    = try(var.ansible.pull.timer, null)
    }
  )

  network_config = templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
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

      dns_servers = local.dns_servers
      domain      = local.subdomain
    }
  )

  meta_data = ""

  pool = libvirt_pool.factory_pool.name

  lifecycle {
    ignore_changes = []
  }
}

###
### Generate the ansible.cfg file
###

locals {
  rendered_ansible_inventory = templatefile("../shared/inventory/hosts.tpl", {
    controller_ips = [
      for vm_name, vm in local.masters_map : local.vm_operator_endpoints[vm_name]
    ]

    worker_ips = [
      for vm_name, vm in local.workers_map : local.vm_operator_endpoints[vm_name]
    ]
  })

  rendered_ansible_config = <<-EOT
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
}


# Generate environment-specific ansible.cfg
resource "local_file" "ansible_config" {
  count = local.write_local_artifacts ? 1 : 0

  filename = "${local.env_path}/ansible.cfg"
  content  = local.rendered_ansible_config

  depends_on = [null_resource.env_directory]
}

# Output the rendered ansible.cfg content in gitops mode, otherwise null
output "gitops_ansible_cfg" {
  description = "GitOps-mode rendered ansible.cfg content."
  value       = local.gitops_mode ? local.rendered_ansible_config : null
}

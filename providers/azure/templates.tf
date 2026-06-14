# Azure-specific template resources for VM provisioning

# Generate cloud-init configuration for all nodes
locals {
  public_kube_api_endpoint = local.first_master_name != null ? azurerm_public_ip.vm-pip[local.first_master_name].ip_address : null
  first_master_fqdn        = local.first_master_name != null ? "${local.first_master_name}.${local.subdomain}" : null

  cloudinit = {
    for vm in concat(local.master_details, local.worker_details, local.vm_details) :
    vm.name => templatefile(
      "${path.module}/../shared/cloud-init/${vm.role == "vm" ? "default" : var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
      {
        os_name  = local.os.os_name
        hostname = vm.name
        fqdn     = "${vm.name}.${local.subdomain}"
        domain   = local.subdomain

        extra_disks    = try(local.vm_disks[vm.name], [])
        extra_packages = var.extra_packages

        clusterid     = var.cluster.id
        timezone      = var.cluster.timezone
        node_username = var.cluster.username

        package_upgrade_enabled = var.cluster.package_upgrade_enabled

        public_key = tls_private_key.global_key.public_key_openssh

        is_first_master        = vm.name == local.first_master_name
        first_master_ip        = local.first_master_name != null ? azurerm_network_interface.vm-interface[local.first_master_name].private_ip_address : null
        first_master_fqdn      = local.first_master_fqdn
        current_public_ip      = azurerm_public_ip.vm-pip[vm.name].ip_address
        current_private_ip     = azurerm_network_interface.vm-interface[vm.name].private_ip_address
        prefer_private_node_ip = false

        node_role = vm.role

        # Optional K3s config
        k3s_token   = local.cluster_token
        k3s_version = var.k3s.version
        k3s_tls_sans = concat(var.k3s.tls_sans,
          compact([local.public_kube_api_endpoint]),
          [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
          [for master in local.master_details : "${master.name}.${local.subdomain}"]
        )
        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        # Optional RKE2 config
        rke2_token   = local.cluster_token
        rke2_version = var.rke2.version
        rke2_tls_sans = concat(var.rke2.tls_sans,
          compact([local.public_kube_api_endpoint]),
          [for master in local.master_details : azurerm_network_interface.vm-interface[master.name].private_ip_address],
          [for master in local.master_details : "${master.name}.${local.subdomain}"]
        )
        rke2_etcd_enabled                   = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled          = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled         = var.rke2.metrics_server_enabled
        rke2_cni                            = var.rke2.cni
        rke2_ingress_type                   = var.rke2.ingress_type
        rke2_kube_proxy_enabled             = try(var.rke2.kube_proxy_enabled, true)
        rke2_cilium_hubble_enabled          = try(var.rke2.cilium.hubble_enabled, false)
        rke2_cilium_operator_replicas       = try(var.rke2.cilium.operator_replicas, 1)
        rke2_cilium_l2announcements_enabled = try(var.rke2.cilium.l2announcements.enabled, false)
        lb_pool_start                       = try(var.rke2.cilium.l2announcements.lb_pool_start, null)
        lb_pool_end                         = try(var.rke2.cilium.l2announcements.lb_pool_end, null)
        network_interface                   = try(var.rke2.cilium.l2announcements.network_interface, null)

        # Optional managed package install
        ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
        ansible_pull_branch   = try(var.ansible.pull.branch, "main")
        ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
        ansible_pull_token    = try(var.ansible.pull.token, null)
        ansible_pull_timer    = try(var.ansible.pull.timer, null)
      }
    )
  }
}

# Generate environment-specific ansible.cfg
resource "local_file" "ansible_config" {
  filename = "${local.env_path}/ansible.cfg"
  content  = <<-EOT
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

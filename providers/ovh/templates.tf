locals {
  master_cloudinit = {
    for vm in local.master_details :
    vm.name => templatefile(
      "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
      {
        os_name  = local.os.os_name
        hostname = vm.name
        fqdn     = "${vm.name}.${local.subdomain}"
        domain   = local.subdomain

        extra_disks = try(local.vm_disks[vm.name], [])

        clusterid     = var.cluster.id
        timezone      = var.cluster.timezone
        node_username = var.cluster.username

        public_key = tls_private_key.global_key.public_key_openssh

        is_first_master        = vm.name == local.first_master_name
        first_master_ip        = vm.name == local.first_master_name ? local.first_master_fqdn : local.cluster_join_endpoint
        first_master_fqdn      = local.first_master_fqdn
        current_private_ip     = try(local.master_private_ip_map[vm.name], null)
        prefer_private_node_ip = false

        node_role = vm.role

        # Optional K3s config
        k3s_token                  = local.cluster_token
        k3s_version                = var.k3s.version
        k3s_tls_sans               = compact(concat(var.k3s.tls_sans, [local.kube_api_bootstrap_endpoint], [for master in local.master_details : "${master.name}.${local.subdomain}"]))
        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        # Optional RKE2 config
        rke2_token                  = local.cluster_token
        rke2_version                = var.rke2.version
        rke2_tls_sans               = compact(concat(var.rke2.tls_sans, [local.kube_api_bootstrap_endpoint], [for master in local.master_details : "${master.name}.${local.subdomain}"]))
        rke2_etcd_enabled           = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled  = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled = var.rke2.metrics_server_enabled

        # Optional managed package install
        ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
        ansible_pull_branch   = try(var.ansible.pull.branch, "main")
        ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
        ansible_pull_token    = try(var.ansible.pull.token, null)
        ansible_pull_timer    = try(var.ansible.pull.timer, null)
      }
    )
  }

  worker_cloudinit = {
    for vm in local.worker_details :
    vm.name => templatefile(
      "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
      {
        os_name  = local.os.os_name
        hostname = vm.name
        fqdn     = "${vm.name}.${local.subdomain}"
        domain   = local.subdomain

        extra_disks = try(local.vm_disks[vm.name], [])

        clusterid     = var.cluster.id
        timezone      = var.cluster.timezone
        node_username = var.cluster.username

        public_key = tls_private_key.global_key.public_key_openssh

        is_first_master        = false
        first_master_ip        = local.private_network_enabled ? local.cluster_join_endpoint : local.first_master_public_ip
        first_master_fqdn      = local.first_master_fqdn
        current_private_ip     = try(local.worker_private_ip_map[vm.name], null)
        prefer_private_node_ip = false

        node_role = vm.role

        # Optional K3s config
        k3s_token                  = local.cluster_token
        k3s_version                = var.k3s.version
        k3s_tls_sans               = compact(concat(var.k3s.tls_sans, [local.public_kube_api_endpoint], [local.first_master_fqdn]))
        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        # Optional RKE2 config
        rke2_token                  = local.cluster_token
        rke2_version                = var.rke2.version
        rke2_tls_sans               = compact(concat(var.rke2.tls_sans, [local.public_kube_api_endpoint], [local.first_master_fqdn]))
        rke2_etcd_enabled           = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled  = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled = var.rke2.metrics_server_enabled

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

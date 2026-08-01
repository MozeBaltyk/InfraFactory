###
### Render the shared cloud-init user-data once per VM.
###

locals {
  rendered = {
    for vm_name, vm in var.vms :
    vm_name => templatefile(
      "${path.module}/../../../shared/cloud-init/${coalesce(vm.cloud_init_selected, var.cloud_init_selected)}/cloud_init.cfg.tftpl",
      {
        hostname     = vm.hostname
        fqdn         = vm.fqdn
        domain       = vm.domain
        node_username = var.node_username
        timezone     = var.timezone
        public_key   = var.public_key

        # Node
        node_role        = vm.node_role
        is_first_master  = vm.is_first_master
        first_master_ip  = vm.first_master_ip
        current_private_ip = vm.current_private_ip

        # Disks and packages
        extra_disks          = vm.extra_disks
        extra_packages       = var.extra_packages
        package_upgrade_enabled = var.package_upgrade_enabled

        # Optional K3s config
        k3s_token   = var.cluster_token
        k3s_version = var.k3s.version
        k3s_tls_sans = vm.k3s_tls_sans
        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        # Optional RKE2 config
        rke2_token                  = var.cluster_token
        rke2_version                = var.rke2.version
        rke2_tls_sans               = vm.rke2_tls_sans
        rke2_etcd_enabled           = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled  = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled = var.rke2.metrics_server_enabled
        rke2_cni                    = var.rke2.cni
        rke2_ingress_type           = var.rke2.ingress_type
        rke2_kube_proxy_enabled     = var.rke2.kube_proxy_enabled
        rke2_cilium_hubble_enabled  = var.rke2.cilium.hubble_enabled
        rke2_cilium_operator_replicas = var.rke2.cilium.operator_replicas
        rke2_cilium_l2announcements_enabled = var.rke2.cilium.l2announcements.enabled
        lb_pool_start               = var.rke2.cilium.l2announcements.lb_pool_start
        lb_pool_end                 = var.rke2.cilium.l2announcements.lb_pool_end
        network_interface           = var.rke2.cilium.l2announcements.network_interface

        # Optional Ansible pull config
        ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
        ansible_pull_branch   = try(var.ansible.pull.branch, "main")
        ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
        ansible_pull_token    = try(var.ansible.pull.token, null)
        ansible_pull_timer    = try(var.ansible.pull.timer, null)
      }
    )
  }
}

output "rendered" {
  description = "Map of VM name to rendered cloud-init user-data."
  value       = local.rendered
}

###
### Render the shared cloud-init user-data once per VM.
###

locals {
  rendered = {
    for vm_name, vm in var.vms :
    vm_name => templatefile(
      "${path.module}/../../../shared/cloud-init/${coalesce(vm.cloud_init_selected, var.cloud_init_selected)}/cloud_init.cfg.tftpl",
      {
        hostname      = vm.hostname
        fqdn          = vm.fqdn
        domain        = vm.domain
        node_username = var.node_username
        timezone      = var.timezone
        public_key    = var.public_key

        # Node
        node_role          = vm.node_role
        is_first_master    = vm.is_first_master
        first_master_ip    = vm.first_master_ip
        current_private_ip = vm.current_private_ip

        # Disks and packages
        extra_disks             = vm.extra_disks
        extra_packages          = var.extra_packages
        package_upgrade_enabled = var.package_upgrade_enabled

        # Optional NFS client mounts targeting this VM
        nfs_client_mounts = [
          for m in var.nfs.client.mounts : {
            server      = m.server
            export_path = m.export_path
            mount_path  = m.mount_path
            options     = m.options
            read_only   = m.read_only
          }
          if contains(m.nodes, vm.hostname)
        ]

        # Optional Object Storage (S3-compatible) credentials targeting this VM
        object_storage_credentials = [
          for c in var.object_storage_credentials : {
            name              = c.name
            bucket            = c.bucket
            region            = c.region
            endpoint          = c.endpoint
            access_key_id     = c.access_key_id
            secret_access_key = c.secret_access_key
          }
          if contains(c.nodes, vm.hostname)
        ]

        # Optional K3s config
        k3s_token                  = var.cluster_token
        k3s_version                = var.k3s.version
        k3s_data_dir               = var.k3s.data_dir
        k3s_tls_sans               = vm.k3s_tls_sans
        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        # Optional RKE2 config
        rke2_token                          = var.cluster_token
        rke2_version                        = var.rke2.version
        rke2_data_dir                       = var.rke2.data_dir
        rke2_tls_sans                       = vm.rke2_tls_sans
        rke2_etcd_enabled                   = var.rke2.etcd_enabled
        rke2_ingress_nginx_enabled          = var.rke2.ingress_nginx_enabled
        rke2_metrics_server_enabled         = var.rke2.metrics_server_enabled
        rke2_cni                            = var.rke2.cni
        rke2_ingress_type                   = var.rke2.ingress_type
        rke2_kube_proxy_enabled             = var.rke2.kube_proxy_enabled
        rke2_flannel_iface                  = vm.flannel_iface
        rke2_cilium_hubble_enabled          = var.rke2.cilium.hubble_enabled
        rke2_cilium_operator_replicas       = var.rke2.cilium.operator_replicas
        rke2_cilium_l2announcements_enabled = var.rke2.cilium.l2announcements.enabled
        lb_pool_start                       = var.rke2.cilium.l2announcements.lb_pool_start
        lb_pool_end                         = var.rke2.cilium.l2announcements.lb_pool_end
        network_interface                   = var.rke2.cilium.l2announcements.network_interface

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

  precondition {
    condition = alltrue([
      for m in var.nfs.client.mounts : alltrue([for node in m.nodes : contains(keys(var.vms), node)])
    ])
    error_message = "nfs.client.mounts[*].nodes must only contain known VM names: ${join(", ", keys(var.vms))}."
  }

  precondition {
    condition = alltrue([
      for c in var.object_storage_credentials : alltrue([for node in c.nodes : contains(keys(var.vms), node)])
    ])
    error_message = "object_storage_credentials[*].nodes must only contain known VM names: ${join(", ", keys(var.vms))}."
  }
}

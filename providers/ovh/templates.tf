locals {
  ovh_private_interface_names = {
    for name, vm in local.all_vms_map :
    name => vm.public_attach ? "ens4" : "ens3"
  }

  common_cloudinit = {
    for vm in local.all_vms_map :
    vm.name => templatefile(
      "${path.module}/../shared/cloud-init/${vm.role == "vm" ? "default" : var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
      {
        ## Base OS
        os_name  = local.os.os_name
        hostname = vm.name
        fqdn     = "${vm.name}.${local.subdomain}"
        domain   = local.subdomain

        ## Node
        node_role     = vm.role
        node_username = var.cluster.username
        timezone      = var.cluster.timezone
        clusterid     = var.cluster.id

        ## Base OS upgrade
        package_upgrade_enabled = var.cluster.package_upgrade_enabled

        ## SSH
        public_key = tls_private_key.global_key.public_key_openssh

        ## Networking
        current_private_ip = vm.private_ip

        is_first_master = (
          vm.role == "master" &&
          vm.name == local.first_master_name
        )

        first_master_ip   = local.kube_api_bootstrap_endpoint
        first_master_fqdn = local.first_master_fqdn

        ## Join endpoint
        cluster_join_endpoint = local.kube_api_bootstrap_endpoint

        ## Disks
        extra_disks = try(local.vm_disks[vm.name], [])

        # Extra packages
        extra_packages = var.extra_packages

        #################################################
        # K3S
        #################################################

        k3s_token   = local.cluster_token
        k3s_version = var.k3s.version

        k3s_tls_sans = distinct(compact(concat(
          var.k3s.tls_sans,
          [local.kube_api_bootstrap_endpoint],
          [local.first_master_fqdn]
        )))

        k3s_etcd_enabled           = var.k3s.etcd_enabled
        k3s_traefik_enabled        = var.k3s.traefik_enabled
        k3s_servicelb_enabled      = var.k3s.servicelb_enabled
        k3s_local_storage_enabled  = var.k3s.local_storage_enabled
        k3s_metrics_server_enabled = var.k3s.metrics_server_enabled
        k3s_flannel_enabled        = var.k3s.flannel_enabled

        #################################################
        # RKE2
        #################################################

        rke2_token   = local.cluster_token
        rke2_version = var.rke2.version

        rke2_tls_sans = distinct(compact(concat(
          var.rke2.tls_sans,
          [local.kube_api_bootstrap_endpoint],
          [local.first_master_fqdn]
        )))

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

        #################################################
        # Ansible Pull
        #################################################

        ansible_pull_repo     = replace(try(var.ansible.pull.repo, ""), "https://", "")
        ansible_pull_branch   = try(var.ansible.pull.branch, "main")
        ansible_pull_playbook = try(var.ansible.pull.playbook, "local.yml")
        ansible_pull_token    = try(var.ansible.pull.token, null)
        ansible_pull_timer    = try(var.ansible.pull.timer, null)
      }
    )
  }

  common_cloudinit_config = {
    for name, body in local.common_cloudinit :
    name => yamldecode(body)
  }

  ovh_private_netplan = {
    for name, vm in local.all_vms_map :
    name => templatefile(
      "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
      {
        # OVH exposes public+private VMs as ens3(public)+ens4(private).
        # Private-only VMs expose the private network as their first NIC: ens3.
        # The OVH port keeps the same fixed IP as this guest-side static netplan.
        interface_id         = local.ovh_private_interface_names[name]
        interface_match_name = local.ovh_private_interface_names[name]
        interface_optional   = true

        use_dhcp           = false
        ip_address         = vm.private_ip
        cidr_prefix        = split("/", local.private_cidr)[1]
        accept_dhcp_routes = false
        accept_dhcp_dns    = false

        network_gateway   = null
        dns_servers       = null
        domain            = local.subdomain
        emit_empty_routes = true
      }
    )
  }

  ovh_private_netplan_write_files = {
    for name, vm in local.all_vms_map :
    name => [
      {
        path        = "/etc/netplan/99-infrafactory-ovh-private.yaml"
        permissions = "0600"
        content     = local.ovh_private_netplan[name]
      },
      {
        path        = "/usr/local/sbin/infrafactory-ovh-private-netplan.sh"
        permissions = "0755"
        content     = <<-EOT
          #!/bin/bash
          set -e

          IFACE="${local.ovh_private_interface_names[name]}"
          NETPLAN_FILE="/etc/netplan/99-infrafactory-ovh-private.yaml"
          PRIVATE_IP="${vm.private_ip}"
          PREFIX="${split("/", local.private_cidr)[1]}"
          CIDR="$PRIVATE_IP/$PREFIX"
          NEED_APPLY=0

          if [ -f "$NETPLAN_FILE" ]; then
            chmod 0600 "$NETPLAN_FILE"
          fi

          if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
            echo "Private interface $IFACE not found" >&2
            exit 1
          fi

          ip link set dev "$IFACE" up

          netplan generate

          if ! ip -4 addr show dev "$IFACE" | grep -Fq " $CIDR"; then
            NEED_APPLY=1
          fi

          if [ "$NEED_APPLY" -eq 1 ]; then
            netplan apply
          fi

          ip addr replace "$CIDR" dev "$IFACE"

          ip -4 route show default dev "$IFACE" | while read -r route; do
            [ -n "$route" ] || continue
            ip -4 route del $route 2>/dev/null || true
          done
        EOT
      },
      {
        path        = "/etc/systemd/system/infrafactory-ovh-private-netplan.service"
        permissions = "0644"
        content     = <<-EOT
          [Unit]
          Description=InfraFactory OVH private netplan route guard
          Wants=network-online.target
          After=network-online.target

          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/infrafactory-ovh-private-netplan.sh

          [Install]
          WantedBy=multi-user.target
        EOT
      }
    ]
  }

  ovh_private_netplan_runcmd = {
    for name, vm in local.all_vms_map :
    name => [
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "infrafactory-ovh-private-netplan.service"],
    ]
  }

  cloudinit_user_data = {
    for name, config in local.common_cloudinit_config :
    name => "#cloud-config\n${yamlencode(merge(config, {
      write_files = concat(
        try(config.write_files, []),
        local.all_vms_map[name].private_attach ? local.ovh_private_netplan_write_files[name] : []
      )

      runcmd = concat(
        local.all_vms_map[name].private_attach ? local.ovh_private_netplan_runcmd[name] : [],
        try(config.runcmd, [])
      )
    }))}"
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

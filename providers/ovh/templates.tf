locals {
  ovh_private_interface_names = {
    for name, vm in local.all_vms_map :
    name => vm.public_attach ? "ens4" : "ens3"
  }
}

# Render shared cloud-init user-data for all nodes
module "cloudinit" {
  source = "../shared/modules/cloudinit-renderer"

  cloud_init_selected     = var.cluster.cloud_init_selected
  node_username           = var.cluster.username
  timezone                = var.cluster.timezone
  extra_packages          = var.extra_packages
  public_key              = local.is_talos ? "" : module.ssh_keys[0].public_key_openssh
  cluster_token           = local.is_talos ? "" : module.ssh_keys[0].cluster_token
  k3s                     = var.k3s
  rke2                    = var.rke2
  ansible                 = var.ansible
  package_upgrade_enabled = var.cluster.package_upgrade_enabled

  vms = local.is_talos ? {} : {
    for vm in local.all_vms_map :
    vm.name => {
      hostname            = vm.name
      fqdn                = "${vm.name}.${local.subdomain}"
      domain              = local.subdomain
      node_role           = vm.role
      cloud_init_selected = vm.role == "vm" ? "default" : null
      is_first_master     = vm.role == "master" && vm.name == local.first_master_name
      first_master_ip     = local.kube_api_bootstrap_endpoint
      current_private_ip  = vm.private_ip
      extra_disks         = try(local.vm_disks[vm.name], [])
      k3s_tls_sans = distinct(compact(concat(
        var.k3s.tls_sans,
        [local.kube_api_bootstrap_endpoint],
        [local.first_master_fqdn]
      )))
      rke2_tls_sans = distinct(compact(concat(
        var.rke2.tls_sans,
        [local.kube_api_bootstrap_endpoint],
        [local.first_master_fqdn]
      )))
    }
  }
}

locals {
  common_cloudinit_config = {
    for name, body in module.cloudinit.rendered :
    name => yamldecode(body)
  }

  ovh_private_netplan = local.is_talos ? {} : {
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

  ovh_private_netplan_write_files = local.is_talos ? {} : {
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

  ovh_private_netplan_runcmd = local.is_talos ? {} : {
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
        local.all_vms_map[name].private_attach && local.all_vms_map[name].public_attach ? local.ovh_private_netplan_write_files[name] : []
      )

      runcmd = concat(
        local.all_vms_map[name].private_attach && local.all_vms_map[name].public_attach ? local.ovh_private_netplan_runcmd[name] : [],
        try(config.runcmd, [])
      )
    }))}"
  }
}

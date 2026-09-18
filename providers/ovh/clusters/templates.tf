locals {
  ovh_private_interface_names = {
    for name, vm in local.all_vms_map :
    name => vm.public_attach ? "ens4" : "ens3"
  }
}

#
# Render shared cloud-init user-data for all nodes
#
module "cloudinit" {
  source = "../../shared/modules/cloudinit-renderer"

  cloud_init_selected     = var.cluster.cloud_init_selected
  node_username           = var.cluster.username
  timezone                = var.cluster.timezone
  extra_packages          = var.extra_packages
  public_key              = module.ssh_keys.public_key_openssh
  cluster_token           = module.ssh_keys.cluster_token
  k3s                     = var.k3s
  rke2                    = var.rke2
  ansible                 = var.ansible
  package_upgrade_enabled = var.cluster.package_upgrade_enabled

  # NFS client mounts are derived from
  # infra.masters/workers/vms.nfs attachments.
  nfs = {
    client = {
      mounts = local.ovh_nfs_client_mounts
    }
  }

  # S3 credentials derived from
  # infra.masters/workers/vms.object_storage attachments.
  object_storage_credentials = local.ovh_object_storage_credentials

  vms = {
    for vm in local.all_vms_map :
    vm.name => {
      hostname            = vm.name
      fqdn                = "${vm.name}.${local.subdomain}"
      domain              = local.subdomain
      node_role           = vm.role
      cloud_init_selected = vm.role == "vm" ? "default" : null

      is_first_master = (
        vm.role == "master" &&
        vm.name == local.first_master_name
      )

      first_master_ip    = local.kube_api_bootstrap_endpoint
      current_private_ip = vm.private_ip

      # Canal/Flannel defaults to the default-route interface.
      # Pin it to the OVH private NIC instead.
      flannel_iface = (
        vm.private_attach
        ? local.ovh_private_interface_names[vm.name]
        : null
      )

      # ponytail: OVH v1 forbids extra_disks (see infra validation); reintroduce
      # local.vm_disks lookup here when the feature lands.
      extra_disks = []

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

#
# Decode shared cloud-init output
#
locals {
  common_cloudinit_config = {
    for name, body in module.cloudinit.rendered :
    name => yamldecode(body)
  }
}

#
# OVH private network netplan.
#
# Shared network_config.cfg.tftpl renders the private static NIC (plus the
# public DHCP NIC via the optional public_iface var), but Nova network_data
# ALSO becomes 50-cloud-init.yaml on every boot with a default via the
# private gateway — and netplan cannot express "remove a route another file
# added". So the yaml declares intent and the oneshot service below deletes
# that one known-stale route family (2026-09-17: network.config = disabled
# does NOT suppress 50-cloud-init.yaml on this stack, verified via console
# log ci-info showing two defaults; the scrub is the mechanism that works).
#
locals {
  ovh_private_netplan = {
    for name, vm in local.all_vms_map :
    name => templatefile(
      "${path.module}/../../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
      {
        # OVH:
        #
        # public + private VM:
        #   ens3 = public (DHCP, via public_iface)
        #   ens4 = private (static, no default route)
        #
        # private-only VM:
        #   ens3 = private (static + default route)
        public_iface = vm.public_attach ? "ens3" : null

        interface_id         = local.ovh_private_interface_names[name]
        interface_match_name = local.ovh_private_interface_names[name]
        interface_optional   = true

        use_dhcp           = false
        ip_address         = vm.private_ip
        cidr_prefix        = split("/", local.private_cidr)[1]
        accept_dhcp_routes = false
        accept_dhcp_dns    = false

        network_gateway = (
          vm.public_attach
          ? null
          : local.private_gateway_ip
        )

        dns_servers = (
          vm.public_attach
          ? null
          : "213.186.33.99"
        )

        domain = local.subdomain

        # No routes key on public nodes: no default via the private NIC.
        # (The stale default 50-cloud-init.yaml adds is deleted by the
        # oneshot service, which netplan syntax cannot express.)
        emit_empty_routes = false
      }
    )
  }

  ovh_private_netplan_write_files = {
    for name, vm in local.all_vms_map :
    name => concat(
      [
        {
          path        = "/etc/netplan/99-infrafactory-ovh-private.yaml"
          permissions = "0600"
          content     = local.ovh_private_netplan[name]
        },
        {
          path        = "/usr/local/sbin/infrafactory-ovh-private-netplan.sh"
          permissions = "0755"

          content = <<-EOT
          #!/bin/bash
          set -euo pipefail

          IFACE="${local.ovh_private_interface_names[name]}"
          NETPLAN_FILE="/etc/netplan/99-infrafactory-ovh-private.yaml"
          PRIVATE_IP="${vm.private_ip}"
          PREFIX="${split("/", local.private_cidr)[1]}"
          CIDR="$PRIVATE_IP/$PREFIX"
          # Static DNS we own on private-only nodes (empty on public nodes,
          # where DHCP owns DNS and there is nothing to verify).
          DNS="${vm.public_attach ? "" : "213.186.33.99"}"

          if [ -f "$NETPLAN_FILE" ]; then
            chmod 0600 "$NETPLAN_FILE"
          fi

          # netplan owns the desired state, but it cannot express the ABSENCE of
          # routes installed by other files: OVH network_data (50-cloud-init.yaml)
          # installs a default via the private gateway, and our file cannot
          # remove it. So: converge declaratively first, verify, and only scrub
          # that one known-stale case imperatively (never addresses).
          if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
            echo "Private interface $IFACE not found" >&2
            exit 1
          fi

          ip link set dev "$IFACE" up

          netplan generate

          addr_ok() {
            ip -4 addr show dev "$IFACE" | grep -Fq " $CIDR"
          }

          routes_ok() {
          %{if vm.public_attach~}
            ! ip -4 route show default dev "$IFACE" | grep -q .
          %{else~}
            ip -4 route show default dev "$IFACE" | grep -q .
          %{endif~}
          }

          # Link DNS as seen by systemd-resolved. A first-boot `netplan
          # apply` can run while resolved is not ready, pushing nothing;
          # the file is correct but the stub resolver stays empty and apt
          # dies resolving (2026-09-17: manual `netplan apply` fixed it
          # instantly). Re-apply until resolved actually holds our server.
          dns_ok() {
            [ -z "$DNS" ] && return 0
            command -v resolvectl >/dev/null 2>&1 || return 0
            resolvectl dns "$IFACE" 2>/dev/null | grep -Fq "$DNS"
          }

          if ! addr_ok || ! routes_ok || ! dns_ok; then
            echo "Network state differs from netplan, running netplan apply once" >&2
            netplan apply
            sleep 2
          fi

          if ! addr_ok; then
            echo "Private IP $CIDR still missing on $IFACE after netplan apply" >&2
            exit 1
          fi

          if ! dns_ok; then
            echo "DNS $DNS still missing on $IFACE after netplan apply (FallbackDNS still answers)" >&2
          fi

          %{if vm.public_attach~}
          # Negating the OVH-installed default via the private interface cannot
          # be expressed declaratively. Without this scrub, return traffic for
          # public inbound connections leaves via the private gateway
          # (asymmetric routing) and the host is unreachable from the internet.
          if ! routes_ok; then
            echo "Removing stale default route via private interface $IFACE" >&2
            ip -4 route show default dev "$IFACE" | while read -r route; do
              [ -n "$route" ] || continue
              ip -4 route del $route || true
            done
          fi
          %{else~}
          if ! routes_ok; then
            echo "No default route via private interface $IFACE after netplan apply" >&2
            ip -4 route show dev "$IFACE" >&2 || true
            exit 1
          fi
          %{endif~}
        EOT
        },
        {
          path        = "/etc/systemd/system/infrafactory-ovh-private-netplan.service"
          permissions = "0644"

          content = <<-EOT
          [Unit]
          Description=InfraFactory OVH private network verify
          Wants=network-online.target
          After=network-online.target

          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/infrafactory-ovh-private-netplan.sh

          [Install]
          WantedBy=multi-user.target
        EOT
        },
        {
          # The oneshot above converges every BOOT, but netplan can be
          # re-applied without reboot (cloud-init hotplug on Neutron port
          # updates, DHCP renewal) — resurrecting the stale private default
          # while the finished oneshot never re-runs (2026-09-17: bastion
          # reachable post-boot, dead minutes later when gateway/LB churn
          # completed; reboot restored it). So re-verify periodically. The
          # script is a silent no-op when converged; worst case ~2 min of
          # asymmetric routing after a hotplug event instead of a permanent
          # outage.
          path        = "/etc/systemd/system/infrafactory-ovh-private-netplan.timer"
          permissions = "0644"

          content = <<-EOT
          [Unit]
          Description=InfraFactory OVH private network verify (periodic)

          [Timer]
          OnBootSec=2min
          OnUnitActiveSec=2min
          Unit=infrafactory-ovh-private-netplan.service

          [Install]
          WantedBy=timers.target
        EOT
        },
      ],
      # Order-independent DNS backstop for private-only nodes (whose sole
      # DNS comes from our 99 file): if link DNS hasn't converged when apt
      # runs, resolved still answers from fallback. Same servers, so zero
      # behavior change once converged. Public nodes skip it (DHCP owns DNS).
      vm.public_attach ? [] : [
        {
          path        = "/etc/systemd/resolved.conf.d/00-infrafactory-dns.conf"
          permissions = "0644"
          content     = "[Resolve]\nFallbackDNS=213.186.33.99\n"
        },
      ]
    )
  }

  ovh_private_netplan_runcmd = {
    for name, vm in local.all_vms_map :
    name => [
      ["systemctl", "daemon-reload"],
      # Pick up the resolved.conf.d drop-in deterministically (no reliance
      # on inotify races); harmless, nothing queries DNS this early.
      ["systemctl", "restart", "systemd-resolved"],
      [
        "systemctl",
        "enable",
        "--now",
        "infrafactory-ovh-private-netplan.service"
      ],
      [
        "systemctl",
        "enable",
        "--now",
        "infrafactory-ovh-private-netplan.timer"
      ],
    ]
  }
}

#
# Shared sshd hardening (S1): identical base policy for the bastion and all
# cluster nodes. The bastion additionally appends PermitOpen (see bastion.tf);
# cluster nodes are full SSH servers and must not carry it.
#
locals {
  sshd_hardening_base = <<-EOT
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    PermitRootLogin no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    AllowTcpForwarding local
  EOT

  ovh_sshd_write_files = [
    {
      path        = "/etc/ssh/sshd_config.d/00-infrafactory-nodes.conf"
      permissions = "0644"
      content     = local.sshd_hardening_base
    },
  ]

  ovh_sshd_runcmd = [
    ["sshd", "-t"],
    ["systemctl", "reload", "ssh"],
  ]
}

#
# Final OVH cloud-init user data
#
# Decode the shared cloud-init YAML, merge OVH-specific additions,
# then serialize it back to valid YAML.
#
locals {
  cloudinit_user_data = {
    for name, config in local.common_cloudinit_config :
    name => "#cloud-config\n${yamlencode(merge(
      config,
      {
        write_files = concat(
          try(config.write_files, []),
          local.all_vms_map[name].private_attach
          ? local.ovh_private_netplan_write_files[name]
          : [],
          local.ovh_sshd_write_files,
        )

        runcmd = concat(
          local.ovh_sshd_runcmd,
          local.all_vms_map[name].private_attach
          ? local.ovh_private_netplan_runcmd[name]
          : [],
          try(config.runcmd, [])
        )
      }
    ))}"
  }
}
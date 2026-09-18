###
### Deterministic IPs per served cluster (shared module, reserved bastion IP
### by convention) + node addresses for the PermitOpen allowlist.
###

module "ipam" {
  source   = "../../shared/modules/ipam"
  for_each = var.clusters

  cidr          = each.value.cidr
  masters_count = each.value.masters
  workers_count = each.value.workers
}

locals {
  bastion_subdomain = "${var.bastion.id}.${var.bastion.domain}"

  cluster_public_keys = compact([
    for name, c in var.clusters :
    c.public_key_file != null ? trimspace(file(c.public_key_file)) : ""
  ])

  # Every served node address, for the SSH-jump allowlist. Empty while no
  # cluster is attached (bastion-first birth): the PermitOpen line is then
  # omitted entirely (an empty allowlist would lock out even forwarding).
  permit_open = join(" ", flatten([
    for name in local.cluster_names_sorted : [
      for ip in concat(
        module.ipam[name].master_ips,
        module.ipam[name].worker_ips,
      ) : "${ip}:22"
    ]
  ]))

  sshd_test_addresses = [
    for cidr in local.ingress_cidrs : cidrhost(cidr, 0)
  ]

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
}

module "cloudinit" {
  source = "../../shared/modules/cloudinit-renderer"

  cloud_init_selected     = "default"
  node_username           = var.bastion.username
  timezone                = var.bastion.timezone
  extra_packages          = []
  public_key              = var.admin_public_keys[0]
  cluster_token           = ""
  ansible                 = {}
  package_upgrade_enabled = var.bastion.package_upgrade_enabled

  vms = {
    (var.bastion.id) = {
      hostname           = var.bastion.id
      fqdn               = local.bastion_subdomain
      domain             = var.bastion.domain
      node_role          = "vm"
      is_first_master    = false
      current_private_ip = null
      extra_disks        = []
      k3s_tls_sans       = []
      rke2_tls_sans      = []
    }
  }
}

locals {
  # One netplan file per attached private NIC (plus none while standalone).
  # Public NIC (ens3, DHCP) is declared in each file via public_iface so a
  # reboot can never resurrect the stale Nova private default from files
  # alone; the oneshot service below deletes it per boot (netplan cannot
  # express that removal — see network_ovh.md §4).
  private_netplans = {
    for name in local.cluster_names_sorted : name => templatefile(
      "${path.module}/../../shared/cloud-init/default/network_config.cfg.tftpl",
      {
        public_iface         = "ens3"
        interface_id         = local.cluster_ifaces[name]
        interface_match_name = local.cluster_ifaces[name]
        interface_optional   = true
        use_dhcp             = false
        ip_address           = module.ipam[name].bastion_ip
        cidr_prefix          = split("/", var.clusters[name].cidr)[1]
        accept_dhcp_routes   = false
        accept_dhcp_dns      = false
        network_gateway      = null
        dns_servers          = null
        domain               = var.bastion.domain
        emit_empty_routes    = false
      }
    )
  }

  private_netplan_write_files = [
    for name in local.cluster_names_sorted : {
      path        = "/etc/netplan/99-infrafactory-ovh-${name}.yaml"
      permissions = "0600"
      content     = local.private_netplans[name]
    }
  ]

  base_config = yamldecode(module.cloudinit.rendered[var.bastion.id])

  cloudinit_user_data = "#cloud-config\n${yamlencode(merge(local.base_config, {
    ssh_pwauth = false
    users = [merge(local.base_config.users[0], {
      lock_passwd         = true
      ssh_authorized_keys = concat(var.admin_public_keys, local.cluster_public_keys)
    })]
    # NOTE (2026-09-17, proven on the guest via `cloud-init schema --system`):
    # `network` is NOT a valid user-data key ("Additional properties are not
    # allowed") — neither `config: disabled` nor a full v2 config has any
    # effect there; cloud-init warns and falls back to datasource
    # network_data. Network intent lives ONLY in the 99 files below; routes
    # converge via the oneshot service. Do not re-add a `network` key here.
    write_files = concat(try(local.base_config.write_files, []), local.private_netplan_write_files, [
      {
        path        = "/usr/local/sbin/infrafactory-ovh-private-netplan.sh"
        permissions = "0755"

        content = <<-EOT
          #!/bin/bash
          set -euo pipefail

          IFACES="${join(" ", [for name in local.cluster_names_sorted : local.cluster_ifaces[name]])}"
          NETPLAN_DIR="/etc/netplan"

          chmod 0600 "$NETPLAN_DIR"/99-infrafactory-ovh-*.yaml 2>/dev/null || true

          for IFACE in $IFACES; do
            if ! ip link show dev "$IFACE" >/dev/null 2>&1; then
              echo "Private interface $IFACE not found" >&2
              exit 1
            fi

            ip link set dev "$IFACE" up
          done

          netplan generate

          addrs_ok() {
            for IFACE in $IFACES; do
              FILE=""
              for f in "$NETPLAN_DIR"/99-infrafactory-ovh-*.yaml; do
                if grep -Fq "$IFACE" "$f" 2>/dev/null; then FILE="$f"; break; fi
              done
              [ -n "$FILE" ] || { echo "No netplan file for $IFACE" >&2; return 1; }
              want="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' "$FILE" | head -n 1)"
              [ -n "$want" ] || { echo "No address in $FILE" >&2; return 1; }
              ip -4 addr show dev "$IFACE" | grep -Fq " $want" || return 1
            done
          }

          routes_ok() {
            for IFACE in $IFACES; do
              ip -4 route show default dev "$IFACE" | grep -q . && return 1
            done
          }

          if ! addrs_ok || ! routes_ok; then
            echo "Network state differs from netplan, running netplan apply once" >&2
            netplan apply
            sleep 2
          fi

          if ! addrs_ok; then
            echo "Private addresses still missing after netplan apply" >&2
            exit 1
          fi

          # Without this scrub, return traffic for public inbound SSH leaves
          # via a private NIC (asymmetric routing) and the bastion is
          # unreachable from the internet. A systemd service (not just runcmd)
          # so a reboot — which re-applies netplan from files — cannot
          # re-break SSH.
          if ! routes_ok; then
            echo "Removing stale default routes via private interfaces ($IFACES)" >&2
            for IFACE in $IFACES; do
              ip -4 route show default dev "$IFACE" | while read -r route; do
                [ -n "$route" ] || continue
                ip -4 route del $route || true
              done
            done
          fi
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
        # Same periodic re-verify as cluster nodes: netplan re-applied
        # without reboot (hotplug/DHCP) resurrects the stale default while
        # the finished oneshot never re-runs.
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
      {
        path        = "/etc/ssh/sshd_config.d/00-infrafactory-bastion.conf"
        permissions = "0644"
        content     = local.permit_open != "" ? "${local.sshd_hardening_base}PermitOpen ${local.permit_open}\n" : local.sshd_hardening_base
      },
      {
        path        = "/usr/local/sbin/infrafactory-verify-bastion-sshd"
        permissions = "0755"
        content     = <<-EOT
          #!/bin/sh
          set -eu

          user="$1"
          host="$2"
          permit_open="$3"
          shift 3

          sshd -t

          check_effective() {
            effective="$(sshd -T -C "user=$user,host=$host,addr=$1")"

            require() {
              if ! printf '%s\n' "$effective" | grep -Fqx -- "$1"; then
                echo "Effective sshd policy mismatch for $2: expected '$1'" >&2
                exit 1
              fi
            }

            require "passwordauthentication no" "$1"
            require "kbdinteractiveauthentication no" "$1"
            require "pubkeyauthentication yes" "$1"
            require "permitrootlogin no" "$1"
            require "allowagentforwarding no" "$1"
            require "x11forwarding no" "$1"
            require "permittunnel no" "$1"
            require "gatewayports no" "$1"
            require "allowtcpforwarding local" "$1"
            require "permitopen $permit_open" "$1"
          }

          for address in "$@"; do
            check_effective "$address"
          done

          systemctl reload ssh

          for address in "$@"; do
            check_effective "$address"
          done
        EOT
      },
      {
        path        = "/etc/sysctl.d/99-infrafactory-bastion.conf"
        permissions = "0644"
        content     = "net.ipv4.ip_forward=0\nnet.ipv6.conf.all.forwarding=0\n"
      }
    ])
    runcmd = concat([
      ["netplan", "generate"],
      ["netplan", "apply"],
      ["systemctl", "daemon-reload"],
      ["systemctl", "enable", "--now", "infrafactory-ovh-private-netplan.service"],
      ["systemctl", "enable", "--now", "infrafactory-ovh-private-netplan.timer"],
      ["sysctl", "--system"],
      ["sshd", "-t"],
      ["systemctl", "reload", "ssh"],
      ],
      local.permit_open != "" ? [concat(
        ["/usr/local/sbin/infrafactory-verify-bastion-sshd", var.bastion.username, var.bastion.id, local.permit_open],
        local.sshd_test_addresses,
      )] : [],
      try(local.base_config.runcmd, []))
  }))}"
}

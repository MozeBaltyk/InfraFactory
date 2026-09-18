locals {
  bastion_name       = "${var.cluster.id}-bastion"
  bastion_private_ip = cidrhost(local.private_cidr, local.private_ip_host_offset_base + var.infra.masters.count + var.infra.workers.count + var.infra.vms.count)

  bastion_image_candidates = [
    for image in data.ovh_cloud_project_images.all.images : image
    if lower(image.status) == "active" &&
    alltrue([for pattern in ["ubuntu", "24.04"] : strcontains(lower(image.name), pattern)]) &&
    !strcontains(lower(image.name), "nvidia") &&
    !strcontains(lower(image.name), "uefi") &&
    !strcontains(lower(image.name), "baremetal")
  ]

  bastion_image_rank = local.lb_ssh_jump_enabled ? sort([
    for image in local.bastion_image_candidates : "${image.name}|${image.id}"
  ]) : []

  bastion_image = local.lb_ssh_jump_enabled ? try(one([
    for image in local.bastion_image_candidates : image
    if "${image.name}|${image.id}" == local.bastion_image_rank[0]
  ]), null) : null

  bastion_flavor_candidates = local.lb_ssh_jump_enabled ? [
    for flavor in data.ovh_cloud_project_flavors.all.flavors : flavor
    if flavor.available && flavor.quota > 0 && flavor.os_type == "linux" &&
    try(flavor.plan_codes.hourly, "") != "" &&
    flavor.disk >= coalesce(try(local.bastion_image.min_disk, null), 0) &&
    flavor.ram >= coalesce(try(local.bastion_image.min_ram, null), 0) &&
    (try(local.bastion_image.flavor_type, null) == null || flavor.type == local.bastion_image.flavor_type)
  ] : []

  bastion_flavor_rank = local.lb_ssh_jump_enabled ? sort([
    for flavor in local.bastion_flavor_candidates : format(
      "%012.3f|%012.3f|%012.3f|%s|%s",
      flavor.vcpus,
      flavor.ram,
      flavor.disk,
      flavor.name,
      flavor.id,
    )
  ]) : []

  bastion_flavor = local.lb_ssh_jump_enabled ? try(one([
    for flavor in local.bastion_flavor_candidates : flavor
    if endswith(local.bastion_flavor_rank[0], "|${flavor.name}|${flavor.id}")
  ]), null) : null
}

resource "terraform_data" "validate_ssh_jump_topology" {
  count = local.ssh_jump_requested ? 1 : 0

  lifecycle {
    precondition {
      condition = (
        !local.ssh_jump_requested ||
        (local.lb_enabled && var.network.kube_api.endpoint == "lb_ip")
      )
      error_message = "network.kube_api.load_balancer.ssh_jump_enabled requires an enabled load balancer with network.kube_api.endpoint = \"lb_ip\". K3s/RKE2 nodes are reached through the bastion via a self-contained ProxyCommand."
    }
  }
}

resource "terraform_data" "validate_bastion" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  input = {
    image_id    = try(local.bastion_image.id, null)
    image_name  = try(local.bastion_image.name, null)
    flavor_id   = try(local.bastion_flavor.id, null)
    flavor_name = try(local.bastion_flavor.name, null)
    vcpus       = try(local.bastion_flavor.vcpus, null)
    ram         = try(local.bastion_flavor.ram, null)
    disk        = try(local.bastion_flavor.disk, null)
  }

  lifecycle {
    precondition {
      condition     = local.bastion_image != null
      error_message = "SSH jump mode requires a compatible active non-UEFI Ubuntu 24.04 image in region '${var.cluster.region}'."
    }

    precondition {
      condition     = local.bastion_flavor != null
      error_message = "SSH jump mode found no compatible available hourly Linux flavor with quota in region '${var.cluster.region}'."
    }
  }
}

module "bastion_cloudinit" {
  count  = local.lb_ssh_jump_enabled ? 1 : 0
  source = "../shared/modules/cloudinit-renderer"

  cloud_init_selected     = "default"
  node_username           = var.cluster.username
  timezone                = var.cluster.timezone
  extra_packages          = []
  public_key              = module.ssh_keys.public_key_openssh
  cluster_token           = ""
  ansible                 = {}
  package_upgrade_enabled = var.cluster.package_upgrade_enabled

  vms = {
    (local.bastion_name) = {
      hostname           = local.bastion_name
      fqdn               = "${local.bastion_name}.${local.subdomain}"
      domain             = local.subdomain
      node_role          = "vm"
      is_first_master    = false
      current_private_ip = local.bastion_private_ip
      extra_disks        = []
      k3s_tls_sans       = []
      rke2_tls_sans      = []
    }
  }
}

locals {
  # Same netplan as cluster nodes (see templates.tf): the bastion is always
  # public + private, so the shared template renders ens3 = public via DHCP
  # (public_iface) + ens4 = static, no default route. Nova network_data still
  # adds its own default via the private gateway (50-cloud-init.yaml), which
  # the oneshot service below deletes — netplan cannot express that removal.
  bastion_private_netplan = local.lb_ssh_jump_enabled ? templatefile(
    "${path.module}/../shared/cloud-init/default/network_config.cfg.tftpl",
    {
      public_iface         = "ens3"
      interface_id         = "ens4"
      interface_match_name = "ens4"
      interface_optional   = true
      use_dhcp             = false
      ip_address           = local.bastion_private_ip
      cidr_prefix          = split("/", local.private_cidr)[1]
      accept_dhcp_routes   = false
      accept_dhcp_dns      = false
      network_gateway      = null
      dns_servers          = null
      domain               = local.subdomain
      emit_empty_routes    = false
    }
  ) : null

  bastion_base_config = try(yamldecode(module.bastion_cloudinit[0].rendered[local.bastion_name]), null)
  # K3s/RKE2 forward to node SSH (:22) through a self-contained ProxyCommand.
  bastion_permit_open = join(" ", [for vm in local.cluster_vms_map : "${vm.private_ip}:22"])
  bastion_sshd_test_addresses = [
    for cidr in local.kube_api_ingress_cidrs : cidrhost(cidr, 0)
  ]

  bastion_cloudinit_user_data = local.lb_ssh_jump_enabled ? "#cloud-config\n${yamlencode(merge(local.bastion_base_config, {
    ssh_pwauth = false
    users = [merge(local.bastion_base_config.users[0], {
      lock_passwd = true
    })]
    # NOTE (2026-09-17, proven on the guest via `cloud-init schema --system`):
    # `network` is NOT a valid user-data key ("Additional properties are not
    # allowed") — neither `config: disabled` nor a full v2 config has any
    # effect there; cloud-init warns and falls back to datasource
    # network_data. Network intent lives ONLY in the 99 file below; routes
    # converge via the oneshot service. Do not re-add a `network` key here.
    write_files = concat(try(local.bastion_base_config.write_files, []), [
      {
        path        = "/etc/netplan/99-infrafactory-ovh-private.yaml"
        permissions = "0600"
        content     = local.bastion_private_netplan
      },
      {
        path        = "/usr/local/sbin/infrafactory-ovh-private-netplan.sh"
        permissions = "0755"

        content = <<-EOT
          #!/bin/bash
          set -euo pipefail

          IFACE="ens4"
          NETPLAN_FILE="/etc/netplan/99-infrafactory-ovh-private.yaml"
          PRIVATE_IP="${local.bastion_private_ip}"
          PREFIX="${split("/", local.private_cidr)[1]}"
          CIDR="$PRIVATE_IP/$PREFIX"

          if [ -f "$NETPLAN_FILE" ]; then
            chmod 0600 "$NETPLAN_FILE"
          fi

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
            ! ip -4 route show default dev "$IFACE" | grep -q .
          }

          if ! addr_ok || ! routes_ok; then
            echo "Network state differs from netplan, running netplan apply once" >&2
            netplan apply
            sleep 2
          fi

          if ! addr_ok; then
            echo "Private IP $CIDR still missing on $IFACE after netplan apply" >&2
            exit 1
          fi

          # Without this scrub, return traffic for public inbound SSH leaves
          # via ens4 (asymmetric routing) and the bastion is unreachable from
          # the internet. A systemd service (not just runcmd) so a reboot —
          # which re-applies netplan from files — cannot re-break SSH.
          if ! routes_ok; then
            echo "Removing stale default route via private interface $IFACE" >&2
            ip -4 route show default dev "$IFACE" | while read -r route; do
              [ -n "$route" ] || continue
              ip -4 route del $route || true
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
        # Same periodic re-verify as cluster nodes (see templates.tf):
        # netplan re-applied without reboot (hotplug/DHCP) resurrects the
        # stale default while the finished oneshot never re-runs.
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
        content     = "${local.sshd_hardening_base}PermitOpen ${local.bastion_permit_open}\n"
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
      concat(
        ["/usr/local/sbin/infrafactory-verify-bastion-sshd", var.cluster.username, local.bastion_name, local.bastion_permit_open],
        local.bastion_sshd_test_addresses,
      ),
    ], try(local.bastion_base_config.runcmd, []))
  }))}" : null
}

resource "terraform_data" "bastion_configuration" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  input = sha256(local.bastion_cloudinit_user_data)
}

resource "openstack_compute_instance_v2" "bastion" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  region            = var.cluster.region
  availability_zone = "nova"

  name        = local.bastion_name
  image_id    = local.bastion_image.id
  flavor_name = local.bastion_flavor.name
  key_pair    = openstack_compute_keypair_v2.cluster.name
  user_data   = local.bastion_cloudinit_user_data

  config_drive = true

  # NIC order defines guest interface order: Ext-Net first keeps
  # ens3(public)/ens4(private); the bastion netplan targets ens4.
  network {
    uuid = data.openstack_networking_network_v2.ext_net.id
  }

  network {
    uuid        = local.private_network_id
    fixed_ip_v4 = local.bastion_private_ip
  }

  timeouts {
    create = "20m"
  }

  lifecycle {
    ignore_changes       = [user_data]
    replace_triggered_by = [terraform_data.bastion_configuration[count.index]]
  }

  depends_on = [
    terraform_data.validate_bastion,
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

locals {
  bastion_public_ipv4_address = local.lb_ssh_jump_enabled ? try(one([
    for net in openstack_compute_instance_v2.bastion[0].network : net.fixed_ip_v4
    if net.uuid == data.openstack_networking_network_v2.ext_net.id
  ]), null) : null
}

resource "terraform_data" "validate_bastion_public_ip" {
  count = local.lb_ssh_jump_enabled ? 1 : 0
  input = local.bastion_public_ipv4_address

  lifecycle {
    precondition {
      condition     = local.bastion_public_ipv4_address != null
      error_message = "Nova did not assign a public IPv4 for the bastion. Re-run apply or check the Ext-Net network and quotas in region."
    }
  }

  depends_on = [openstack_compute_instance_v2.bastion]
}

resource "openstack_networking_secgroup_v2" "bastion" {
  count                = local.lb_ssh_jump_enabled ? 1 : 0
  name                 = "${var.cluster.id}-${terraform.workspace}-bastion"
  description          = "InfraFactory ${var.cluster.id} SSH bastion"
  region               = var.cluster.region
  delete_default_rules = true
}

resource "openstack_networking_secgroup_rule_v2" "bastion_ssh" {
  for_each = local.lb_ssh_jump_enabled ? toset(local.kube_api_ingress_cidrs) : []

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.value
  security_group_id = openstack_networking_secgroup_v2.bastion[0].id
  region            = var.cluster.region
}

resource "openstack_networking_secgroup_rule_v2" "bastion_egress" {
  count             = local.lb_ssh_jump_enabled ? 1 : 0
  direction         = "egress"
  ethertype         = "IPv4"
  security_group_id = openstack_networking_secgroup_v2.bastion[0].id
  region            = var.cluster.region
}

data "openstack_networking_port_v2" "bastion_public" {
  count     = local.lb_ssh_jump_enabled ? 1 : 0
  device_id = openstack_compute_instance_v2.bastion[0].id
  fixed_ip  = local.bastion_public_ipv4_address
  region    = var.cluster.region

  depends_on = [terraform_data.validate_bastion_public_ip]
}

data "openstack_networking_port_v2" "bastion_private" {
  count      = local.lb_ssh_jump_enabled ? 1 : 0
  device_id  = openstack_compute_instance_v2.bastion[0].id
  network_id = local.private_network_id
  fixed_ip   = local.bastion_private_ip
  region     = var.cluster.region
}

resource "openstack_networking_port_secgroup_associate_v2" "bastion_public" {
  count              = local.lb_ssh_jump_enabled ? 1 : 0
  port_id            = data.openstack_networking_port_v2.bastion_public[0].id
  security_group_ids = [openstack_networking_secgroup_v2.bastion[0].id]
  enforce            = true
  region             = var.cluster.region
}

resource "openstack_networking_port_secgroup_associate_v2" "bastion_private" {
  count              = local.lb_ssh_jump_enabled ? 1 : 0
  port_id            = data.openstack_networking_port_v2.bastion_private[0].id
  security_group_ids = [openstack_networking_secgroup_v2.bastion[0].id]
  enforce            = true
  region             = var.cluster.region
}

resource "terraform_data" "bastion_cloudinit_ready" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  triggers_replace = [
    openstack_compute_instance_v2.bastion[0].id,
    local.bastion_public_ipv4_address,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      # 60 attempts x ~10s ~= 10 minutes. First boot is slow (Nova
      # scheduling + firmware + cloud-init + package upgrades ≈ 5+ min to
      # SSH-ready; 2026-09-17 the 5-minute budget expired ~1 min before the
      # scrubbed guest answered). Past 10 min unreachable really means broken
      # (security groups, cloud-init netplan, or OVH network issue). The inner
      # `timeout 900 cloud-init status --wait` still allows a reachable
      # bastion up to 15 minutes to finish cloud-init within one attempt.
      for attempt in $(seq 1 60); do
        if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o ConnectTimeout=5 "$BASTION_HOST" \
          timeout 900 cloud-init status --wait; then
          exit 0
        fi
        sleep 5
      done
      echo "Bastion $BASTION_HOST still unreachable after ~10 minutes, aborting." >&2
      exit 1
    EOT

    environment = {
      BASTION_HOST = "${var.cluster.username}@${local.bastion_public_ipv4_address}"
      KEY_PATH     = abspath("${local.env_path}/.key.private")
    }
  }

  depends_on = [
    module.ssh_keys,
    openstack_networking_port_secgroup_associate_v2.bastion_public,
    openstack_networking_port_secgroup_associate_v2.bastion_private,
  ]
}

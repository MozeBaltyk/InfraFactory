locals {
  bastion_name       = "${var.cluster.id}-bastion"
  bastion_private_ip = cidrhost(local.private_cidr, local.private_ip_host_offset_base + var.infra.masters.count + var.infra.workers.count + var.infra.vms.count)

  bastion_image_candidates = [
    for image in data.ovh_cloud_project_images.all.images : image
    if lower(image.status) == "active" &&
    alltrue([for pattern in ["ubuntu", "24.04"] : strcontains(lower(image.name), pattern)]) &&
    !strcontains(lower(image.name), "nvidia") &&
    !strcontains(lower(image.name), "uefi")
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
        (local.lb_enabled && !local.is_talos && var.network.kube_api.endpoint == "lb_ip")
      )
      error_message = "network.kube_api.load_balancer.ssh_jump_enabled requires an enabled K3s/RKE2 load balancer with network.kube_api.endpoint = \"lb_ip\" and is not supported with Talos."
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
  public_key              = module.ssh_keys[0].public_key_openssh
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
  bastion_private_netplan = local.lb_ssh_jump_enabled ? templatefile(
    "${path.module}/../shared/cloud-init/default/network_config.cfg.tftpl",
    {
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
      emit_empty_routes    = true
    }
  ) : null

  bastion_base_config = try(yamldecode(module.bastion_cloudinit[0].rendered[local.bastion_name]), null)
  bastion_permit_open = join(" ", [for vm in local.cluster_vms_map : "${vm.private_ip}:22"])
  bastion_sshd_test_addresses = [
    for cidr in local.kube_api_ingress_cidrs : cidrhost(cidr, 0)
  ]

  bastion_cloudinit_user_data = local.lb_ssh_jump_enabled ? "#cloud-config\n${yamlencode(merge(local.bastion_base_config, {
    ssh_pwauth = false
    users = [merge(local.bastion_base_config.users[0], {
      lock_passwd = true
    })]
    write_files = concat(try(local.bastion_base_config.write_files, []), [
      {
        path        = "/etc/netplan/99-infrafactory-ovh-private.yaml"
        permissions = "0600"
        content     = local.bastion_private_netplan
      },
      {
        path        = "/etc/ssh/sshd_config.d/00-infrafactory-bastion.conf"
        permissions = "0644"
        content     = <<-EOT
          PasswordAuthentication no
          KbdInteractiveAuthentication no
          PubkeyAuthentication yes
          PermitRootLogin no
          AllowAgentForwarding no
          X11Forwarding no
          PermitTunnel no
          GatewayPorts no
          AllowTcpForwarding local
          PermitOpen ${local.bastion_permit_open}
        EOT
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

resource "ovh_cloud_project_instance" "bastion" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"

  name      = local.bastion_name
  user_data = local.bastion_cloudinit_user_data

  boot_from {
    image_id = local.bastion_image.id
  }

  flavor {
    flavor_id = local.bastion_flavor.id
  }

  ssh_key {
    name = ovh_cloud_project_ssh_key.cluster[0].name
  }

  network {
    public = true
    private {
      ip = local.bastion_private_ip
      network {
        id        = local.private_network_id
        subnet_id = local.private_subnet_id
      }
    }
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
    terraform_data.validate_existing_private_network,
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

resource "time_sleep" "wait_bastion_networks" {
  count           = local.lb_ssh_jump_enabled ? 1 : 0
  create_duration = "30s"

  triggers = {
    instance_id = ovh_cloud_project_instance.bastion[0].id
  }
}

data "ovh_cloud_project_instance" "bastion" {
  count        = local.lb_ssh_jump_enabled ? 1 : 0
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  instance_id  = ovh_cloud_project_instance.bastion[0].id

  depends_on = [time_sleep.wait_bastion_networks]
}

locals {
  bastion_public_ipv4_address = local.lb_ssh_jump_enabled ? try(one([
    for addr in data.ovh_cloud_project_instance.bastion[0].addresses : addr.ip
    if addr.version == 4 && addr.ip != local.bastion_private_ip
  ]), null) : null
}

resource "terraform_data" "validate_bastion_public_ip" {
  count = local.lb_ssh_jump_enabled ? 1 : 0
  input = local.bastion_public_ipv4_address

  lifecycle {
    precondition {
      condition     = local.bastion_public_ipv4_address != null
      error_message = "OVH did not publish a public IPv4 for the bastion within 30s. Re-run apply after the OVH API converges."
    }
  }

  depends_on = [data.ovh_cloud_project_instance.bastion]
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
  device_id = ovh_cloud_project_instance.bastion[0].id
  fixed_ip  = local.bastion_public_ipv4_address
  region    = var.cluster.region

  depends_on = [terraform_data.validate_bastion_public_ip]
}

data "openstack_networking_port_v2" "bastion_private" {
  count      = local.lb_ssh_jump_enabled ? 1 : 0
  device_id  = ovh_cloud_project_instance.bastion[0].id
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

resource "local_sensitive_file" "ssh_config" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  filename        = "${local.env_path}/ssh_config"
  file_permission = "0600"
  content         = <<-EOT
Host *
  IdentityFile ${jsonencode(abspath("${local.env_path}/.key.private"))}
  IdentitiesOnly yes
  ForwardAgent no
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null

Host ${local.bastion_name}
  HostName ${local.bastion_public_ipv4_address}
  User ${var.cluster.username}

%{for name, vm in local.private_cluster_vms_map~}
Host ${name}
  HostName ${vm.private_ip}
  User ${var.cluster.username}
  ProxyJump ${local.bastion_name}

%{endfor~}
EOT
}

resource "terraform_data" "bastion_cloudinit_ready" {
  count = local.lb_ssh_jump_enabled ? 1 : 0

  triggers_replace = [
    ovh_cloud_project_instance.bastion[0].id,
    local.bastion_public_ipv4_address,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      for attempt in $(seq 1 60); do
        if ssh -F "$SSH_CONFIG" -o ConnectTimeout=5 "$HOST_ALIAS" \
          timeout 900 cloud-init status --wait; then
          exit 0
        fi
        sleep 5
      done
      exit 1
    EOT

    environment = {
      HOST_ALIAS = local.bastion_name
      SSH_CONFIG = abspath("${local.env_path}/ssh_config")
    }
  }

  depends_on = [
    module.ssh_keys,
    local_sensitive_file.ssh_config,
    openstack_networking_port_secgroup_associate_v2.bastion_public,
    openstack_networking_port_secgroup_associate_v2.bastion_private,
  ]
}

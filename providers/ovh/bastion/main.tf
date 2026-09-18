###
### Image + flavor lookup (same policy as the former embedded bastion:
### active non-UEFI Ubuntu 24.04, smallest fitting hourly flavor).
###

data "ovh_cloud_project_images" "all" {
  service_name = var.ovh_project_service_name
  region       = var.bastion.region
}

data "ovh_cloud_project_flavors" "all" {
  service_name = var.ovh_project_service_name
  region       = var.bastion.region
}

locals {
  bastion_image_candidates = [
    for image in data.ovh_cloud_project_images.all.images : image
    if lower(image.status) == "active" &&
    alltrue([for pattern in ["ubuntu", "24.04"] : strcontains(lower(image.name), pattern)]) &&
    !strcontains(lower(image.name), "nvidia") &&
    !strcontains(lower(image.name), "uefi") &&
    !strcontains(lower(image.name), "baremetal")
  ]

  bastion_image_rank = sort([
    for image in local.bastion_image_candidates : "${image.name}|${image.id}"
  ])

  bastion_image = try(one([
    for image in local.bastion_image_candidates : image
    if "${image.name}|${image.id}" == local.bastion_image_rank[0]
  ]), null)

  bastion_flavor_candidates = [
    for flavor in data.ovh_cloud_project_flavors.all.flavors : flavor
    if flavor.available && flavor.quota > 0 && flavor.os_type == "linux" &&
    try(flavor.plan_codes.hourly, "") != "" &&
    flavor.disk >= coalesce(try(local.bastion_image.min_disk, null), 0) &&
    flavor.ram >= coalesce(try(local.bastion_image.min_ram, null), 0) &&
    (try(local.bastion_image.flavor_type, null) == null || flavor.type == local.bastion_image.flavor_type)
  ]

  bastion_flavor_rank = sort([
    for flavor in local.bastion_flavor_candidates : format(
      "%012.3f|%012.3f|%012.3f|%s|%s",
      flavor.vcpus,
      flavor.ram,
      flavor.disk,
      flavor.name,
      flavor.id,
    )
  ])

  bastion_flavor = try(one([
    for flavor in local.bastion_flavor_candidates : flavor
    if endswith(local.bastion_flavor_rank[0], "|${flavor.name}|${flavor.id}")
  ]), null)
}

resource "terraform_data" "validate_bastion" {
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
      error_message = "Bastion requires a compatible active non-UEFI Ubuntu 24.04 image in region '${var.bastion.region}'."
    }

    precondition {
      condition     = local.bastion_flavor != null
      error_message = "Bastion found no compatible available hourly Linux flavor with quota in region '${var.bastion.region}'."
    }
  }
}

###
### Nova keypair: the OVH project SSH key is NOT visible to Nova
### (Invalid key_name), so register the admin key natively.
###

resource "random_id" "ssh_key_suffix" {
  byte_length = 4
}

resource "openstack_compute_keypair_v2" "bastion" {
  region     = var.bastion.region
  name       = "${var.bastion.id}-${random_id.ssh_key_suffix.hex}"
  public_key = trimspace(var.admin_public_keys[0])
}

###
### Bastion VM. NIC order defines guest interface order: Ext-Net first keeps
### ens3 (public); attached clusters follow in sorted key order
### (ens4, ens5, ...), matching templates.tf.
###
### Phase 1 uses plain network blocks: attaching another cluster replaces the
### VM (new public IP). Phase 2 switches to ports + interface_attach
### (hot-attach, VM stays).
###

resource "openstack_compute_instance_v2" "bastion" {
  region            = var.bastion.region
  availability_zone = "nova"

  name        = var.bastion.id
  image_id    = local.bastion_image.id
  flavor_name = local.bastion_flavor.name
  key_pair    = openstack_compute_keypair_v2.bastion.name
  user_data   = local.cloudinit_user_data

  config_drive = true

  network {
    uuid = data.openstack_networking_network_v2.ext_net.id
  }

  dynamic "network" {
    for_each = local.cluster_names_sorted

    content {
      uuid        = local.cluster_private_network_ids[network.value]
      fixed_ip_v4 = module.ipam[network.value].bastion_ip
    }
  }

  timeouts {
    create = "20m"
  }

  # Day-2 convergence (keys, NICs, PermitOpen) is Ansible-owned, never a
  # replacement: there is deliberately NO replace_triggered_by here (unlike
  # the former embedded bastion).
  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [
    terraform_data.validate_bastion,
    terraform_data.validate_cluster_networks,
  ]
}

locals {
  bastion_public_ipv4_address = try(one([
    for net in openstack_compute_instance_v2.bastion.network : net.fixed_ip_v4
    if net.uuid == data.openstack_networking_network_v2.ext_net.id
  ]), null)
}

resource "terraform_data" "validate_bastion_public_ip" {
  input = local.bastion_public_ipv4_address

  lifecycle {
    precondition {
      condition     = local.bastion_public_ipv4_address != null
      error_message = "Nova did not assign a public IPv4 for the bastion. Re-run apply or check the Ext-Net network and quotas in region."
    }
  }

  depends_on = [openstack_compute_instance_v2.bastion]
}

###
### Port security-group association (public + every attached private port).
###

data "openstack_networking_port_v2" "bastion_public" {
  device_id = openstack_compute_instance_v2.bastion.id
  fixed_ip  = local.bastion_public_ipv4_address
  region    = var.bastion.region

  depends_on = [terraform_data.validate_bastion_public_ip]
}

data "openstack_networking_port_v2" "bastion_private" {
  for_each = toset(local.cluster_names_sorted)

  device_id  = openstack_compute_instance_v2.bastion.id
  network_id = local.cluster_private_network_ids[each.key]
  fixed_ip   = module.ipam[each.key].bastion_ip
  region     = var.bastion.region
}

resource "openstack_networking_port_secgroup_associate_v2" "bastion_public" {
  port_id            = data.openstack_networking_port_v2.bastion_public.id
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]
  enforce            = true
  region             = var.bastion.region
}

resource "openstack_networking_port_secgroup_associate_v2" "bastion_private" {
  for_each = toset(local.cluster_names_sorted)

  port_id            = data.openstack_networking_port_v2.bastion_private[each.key].id
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]
  enforce            = true
  region             = var.bastion.region
}

###
### Readiness probe: fail fast when the bastion never answers SSH.
### KEY_PATH must match one of the authorized keys (admin key at birth).
###

resource "terraform_data" "bastion_cloudinit_ready" {
  triggers_replace = [
    openstack_compute_instance_v2.bastion.id,
    local.bastion_public_ipv4_address,
  ]

  provisioner "local-exec" {
    command = <<-EOT
      # 60 attempts x ~10s ~= 10 minutes. First boot is slow (Nova
      # scheduling + firmware + cloud-init + package upgrades ≈ 5+ min to
      # SSH-ready). Past 10 min unreachable really means broken
      # (security groups, cloud-init netplan, or OVH network issue).
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
      BASTION_HOST = "${var.bastion.username}@${local.bastion_public_ipv4_address}"
      KEY_PATH     = var.probe_ssh_private_key_path
    }
  }

  depends_on = [
    openstack_networking_port_secgroup_associate_v2.bastion_public,
    openstack_networking_port_secgroup_associate_v2.bastion_private,
  ]
}

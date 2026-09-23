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
    (try(local.bastion_image.flavor_type, null) == null || flavor.type == local.bastion_image.flavor_type) &&
    (var.bastion.flavor_name == null || flavor.name == var.bastion.flavor_name)
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

    precondition {
      condition     = (length(var.admin_public_keys) > 0) == (var.probe_ssh_private_key_path != null)
      error_message = "Provide admin_public_keys and probe_ssh_private_key_path together, or neither (to auto-generate a keypair in env/OVH/<workspace>/)."
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
  public_key = trimspace(local.admin_public_keys[0])
}

###
### Bastion VM. `ens3` is the public NIC (Ext-Net first). Attached clusters
### add private NICs by sorted key order, but their guest names are NOT
### predictable (hot-attach); day-2 netplan matches each Neutron port MAC and
### renames to a conventional iface via the converge role.
###
### Private NICs are hot-attached ports (below), never inline network blocks:
### adding another cluster creates only a port + attach, the VM (and its
### public IP) stays.
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

  timeouts {
    create = "20m"
  }

  # Day-2 convergence (keys, NICs, PermitOpen) is Ansible-owned, never a
  # replacement: no replace_triggered_by here.
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
### Per-cluster private ports (fixed reserved IP from the shared IPAM
### convention) + hot-attach to the running VM. Adding a cluster creates only
### these two resources; the VM above is untouched (its arguments never
### reference var.clusters, and user_data drift is ignored + Ansible-owned).
### for_each over the sorted cluster names keeps NIC order deterministic
### (Ext-Net first, then clusters in order — ens3 public, ens4+ private).
###

resource "openstack_networking_port_v2" "bastion_private" {
  for_each = toset(local.cluster_names_sorted)

  region     = var.bastion.region
  name       = "${var.bastion.id}-${each.key}"
  network_id = local.cluster_private_network_ids[each.key]

  # Single subnet per cluster network (enforced by
  # terraform_data.validate_cluster_networks), so Neutron resolves the
  # subnet from the address alone — no OpenStack subnet lookup needed.
  fixed_ip {
    ip_address = module.ipam[each.key].bastion_ip
  }

  # Same SG semantics as before (SSH in from ingress CIDRs, egress open),
  # now declared on the managed port instead of a post-hoc associate.
  security_group_ids = [openstack_networking_secgroup_v2.bastion.id]

  depends_on = [terraform_data.validate_cluster_networks]
}

resource "openstack_compute_interface_attach_v2" "bastion_private" {
  for_each = toset(local.cluster_names_sorted)

  region      = var.bastion.region
  instance_id = openstack_compute_instance_v2.bastion.id
  port_id     = openstack_networking_port_v2.bastion_private[each.key].id
}

###
### Public port security-group association. Unlike the private NICs, the
### Ext-Net port is implicitly created by Nova via the VM's network block,
### so it cannot be a managed port resource without an import — the
### data-source lookup + associate stays for this one port only.
###

data "openstack_networking_port_v2" "bastion_public" {
  device_id = openstack_compute_instance_v2.bastion.id
  fixed_ip  = local.bastion_public_ipv4_address
  region    = var.bastion.region

  depends_on = [terraform_data.validate_bastion_public_ip]
}

resource "openstack_networking_port_secgroup_associate_v2" "bastion_public" {
  port_id            = data.openstack_networking_port_v2.bastion_public.id
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
      # 10 attempts x ~60s ~= 10 minutes. First boot is slow (Nova
      # scheduling + firmware + cloud-init + package upgrades ≈ 5+ min to
      # SSH-ready). Past 10 min unreachable really means broken
      # (security groups, cloud-init netplan, or OVH network issue).
      for attempt in $(seq 1 10); do
        # cloud-init "done" exits 0; "degraded done" (recoverable warnings,
        # e.g. schema validation) exits 2. Both mean the bastion finished
        # first boot and is SSH-ready. Only a fatal error (3) or a still-running
        # timeout (124) is a failure.
        if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o IdentitiesOnly=yes -o ConnectTimeout=5 "$BASTION_HOST" \
          'timeout 900 cloud-init status --wait; rc=$?; [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]'; then
          exit 0
        fi
        sleep 60
      done
      echo "Bastion $BASTION_HOST still unreachable after ~10 minutes, aborting." >&2
      exit 1
    EOT

    environment = {
      BASTION_HOST = "${var.bastion.username}@${local.bastion_public_ipv4_address}"
      KEY_PATH     = local.probe_ssh_private_key_path
    }
  }

  depends_on = [
    openstack_networking_port_secgroup_associate_v2.bastion_public,
    openstack_compute_interface_attach_v2.bastion_private,
  ]
}

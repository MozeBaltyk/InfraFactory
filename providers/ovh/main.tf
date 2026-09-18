###
### Look for the image id and flavor id in the region and validate it exists before creating any resources
###

data "ovh_cloud_project_images" "all" {
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
}

data "ovh_cloud_project_flavors" "all" {
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
}

###
### SSH key — push the generated public key to OVH so it can be injected into VMs
###

resource "random_id" "ssh_key_suffix" {
  byte_length = 4
}

resource "ovh_cloud_project_ssh_key" "cluster" {
  service_name = var.ovh_project_service_name
  name         = "${terraform.workspace}-${random_id.ssh_key_suffix.hex}"
  public_key   = trimspace(module.ssh_keys.public_key_openssh)
}

# Nova keypair for openstack_compute_instance_v2: the OVH SSH key above is
# NOT visible to Nova (Invalid key_name), so register the same public key
# natively. // ponytail: two keys, same material; drop the OVH one once green.
resource "openstack_compute_keypair_v2" "cluster" {
  region     = var.cluster.region
  name       = "${terraform.workspace}-${random_id.ssh_key_suffix.hex}"
  public_key = trimspace(module.ssh_keys.public_key_openssh)
}

locals {
  requested_flavors = toset(compact([
    var.infra.masters.instance_size,
    var.infra.workers.instance_size,
    var.infra.vms.instance_size
  ]))

  flavor_map = {
    for flavor in data.ovh_cloud_project_flavors.all.flavors :
    flavor.name => flavor
    if contains(local.requested_flavors, flavor.name)
  }

  selected_images = [
    for image in data.ovh_cloud_project_images.all.images :
    image
    if(
      alltrue([
        for pattern in local.os.image.search_patterns :
        strcontains(lower(image.name), lower(pattern))
      ])
      &&
      !strcontains(lower(image.name), "nvidia")
      &&
      !strcontains(lower(image.name), "baremetal")
      &&
      !strcontains(lower(image.name), "uefi")
    )
  ]

  preferred_images = [
    for image in local.selected_images :
    image
    if !strcontains(lower(image.name), "uefi")
  ]

  selected_image = try(
    local.preferred_images[0],
    local.selected_images[0],
    null
  )

}

resource "terraform_data" "validate_image" {
  lifecycle {
    precondition {
      condition = local.selected_image != null
      error_message = format(
        "No OVH image matching patterns [%s] found in region '%s'.",
        join(", ", local.os.image.search_patterns),
        var.cluster.region
      )
    }
  }
}

resource "terraform_data" "validate_flavors" {
  lifecycle {
    precondition {
      condition = alltrue([
        for flavor_name in local.requested_flavors :
        contains(keys(local.flavor_map), flavor_name)
      ])

      error_message = "One or more OVH flavors were not found in region '${var.cluster.region}'."
    }
  }
}

###
### Create VMs via Nova with config_drive: user_data reaches the guest via
### the attached config-drive, so private subnets run with dhcp = false and
### static guest netplan instead of the 169.254.169.254 metadata proxy.
###
### Image/flavor mapping from the OVH catalog above:
###   image_id    = OVH image id (Glance image UUID, same namespace)
###   flavor_name = requested instance_size (Nova flavor name, e.g. "b2-7")
###   key_pair    = Nova keypair (openstack_compute_keypair_v2, same public key
###                 as the OVH SSH key which Nova cannot see)
###

resource "openstack_compute_instance_v2" "vms" {
  for_each = local.public_vms_map

  region            = var.cluster.region
  availability_zone = "nova"

  name        = each.value.name
  image_id    = local.selected_image.id
  flavor_name = each.value.instance_size
  key_pair    = openstack_compute_keypair_v2.cluster.name
  user_data   = each.value.user_data_enabled ? local.cloudinit_user_data[each.key] : null

  config_drive = true

  # NIC order defines guest interface order: Ext-Net first preserves the
  # ens3(public)/ens4(private) mapping used by templates.tf.
  dynamic "network" {
    for_each = each.value.public_attach ? [each.value] : []

    content {
      uuid = data.openstack_networking_network_v2.ext_net.id
    }
  }

  dynamic "network" {
    for_each = each.value.private_attach ? [each.value] : []

    content {
      uuid        = local.private_network_id
      fixed_ip_v4 = network.value.private_ip
    }
  }

  timeouts {
    create = "20m"
  }

  # cloud-init user_data is first-boot data; mutable cluster reconciliation is handled by Ansible.
  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [
    terraform_data.validate_image,
    terraform_data.validate_flavors,
    terraform_data.validate_existing_private_network,
    ovh_cloud_project_network_private_subnet_v2.cluster,
    # The NFS share's export path is already an implicit dependency via
    # user_data, but the access ACL isn't referenced by any value -- without
    # this, a node can boot and attempt its mount before the ACL exists,
    # failing with "access denied by server".
    ovh_cloud_storage_file_share_acl.nfs,
  ]
}

resource "openstack_compute_instance_v2" "private_cluster" {
  for_each = local.private_cluster_vms_map

  region            = var.cluster.region
  availability_zone = "nova"

  name        = each.value.name
  image_id    = local.selected_image.id
  flavor_name = each.value.instance_size
  key_pair    = openstack_compute_keypair_v2.cluster.name
  user_data   = each.value.user_data_enabled ? local.cloudinit_user_data[each.key] : null

  config_drive = true

  # Single NIC: the private network is the guest's first (and only)
  # interface (ens3), matching templates.tf.
  network {
    uuid        = local.private_network_id
    fixed_ip_v4 = each.value.private_ip
  }

  timeouts {
    create = "20m"
  }

  lifecycle {
    ignore_changes = [user_data]
  }

  depends_on = [
    terraform_data.validate_image,
    terraform_data.validate_flavors,
    ovh_cloud_gateway.kube_api,
    ovh_cloud_storage_file_share_acl.nfs,
  ]
}

###
### Topology Dynamic: Catch the ips
###
### Public IPv4s come straight from Nova state (Ext-Net port, DHCP-assigned
### at create), so no re-read data source or wait is needed -- unlike the
### OVH API, which was slow to publish them.
###
locals {
  # Public IPv4 per public-attached VM, matched by Ext-Net network UUID.
  vm_public_ipv4_addresses = {
    for name, instance in openstack_compute_instance_v2.vms :
    name => try(one([
      for net in instance.network : net.fixed_ip_v4
      if net.uuid == data.openstack_networking_network_v2.ext_net.id
    ]), null)
  }

  # Private IPv4: already known from the deterministic cidrhost assignment.
  vm_private_ipv4_addresses = { for name, vm in local.all_vms_map : name => vm.private_ip }

  # Names of public-attached VMs whose public IPv4 Nova has not (yet) returned.
  # Used by the precondition below to fail with a clear message instead
  # of letting compact() silently drop nodes from the Ansible inventory.
  vms_missing_public_ip = [
    for name, ip in local.vm_public_ipv4_addresses :
    name if local.all_vms_map[name].public_attach && ip == null
  ]
}

# Fail fast if any public-attached VM is missing a public IPv4. Without
# this, compact() in output.tf would silently exclude the VM from the
# generated Ansible inventory and apply would "succeed" with a broken hosts.ini.
resource "terraform_data" "validate_public_ips" {
  input = local.vm_public_ipv4_addresses

  lifecycle {
    precondition {
      condition = length(local.vms_missing_public_ip) == 0
      error_message = format(
        "Nova did not assign a public IPv4 for the following VMs: [%s]. Re-run apply or check the Ext-Net network and quotas in region.",
        join(", ", local.vms_missing_public_ip),
      )
    }
  }

  depends_on = [
    openstack_compute_instance_v2.vms,
  ]
}

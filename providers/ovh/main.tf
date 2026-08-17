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
    )
  ]

  preferred_images = [
    for image in local.selected_images :
    image
    if !strcontains(lower(image.name), "uefi")
  ]

  selected_image = try(
    one(local.preferred_images),
    one(local.selected_images),
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
### Create VMs
###

resource "ovh_cloud_project_instance" "vms" {
  for_each = local.public_vms_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"

  name      = each.value.name
  user_data = each.value.user_data_enabled ? local.cloudinit_user_data[each.key] : null

  boot_from {
    image_id = local.selected_image.id
  }

  flavor {
    flavor_id = local.flavor_map[each.value.instance_size].id
  }

  dynamic "ssh_key" {
    for_each = [ovh_cloud_project_ssh_key.cluster.name]

    content {
      name = ssh_key.value
    }
  }

  network {
    public = each.value.public_attach

    dynamic "private" {
      for_each = each.value.private_attach ? [each.value] : []
      iterator = private_network

      content {
        ip = private_network.value.private_ip
        network {
          id        = local.private_network_id
          subnet_id = local.private_subnet_id
        }
      }
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
  ]
}

resource "ovh_cloud_project_instance" "private_cluster" {
  for_each = local.private_cluster_vms_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"

  name      = each.value.name
  user_data = each.value.user_data_enabled ? local.cloudinit_user_data[each.key] : null

  boot_from {
    image_id = local.selected_image.id
  }

  flavor {
    flavor_id = local.flavor_map[each.value.instance_size].id
  }

  dynamic "ssh_key" {
    for_each = [ovh_cloud_project_ssh_key.cluster.name]

    content {
      name = ssh_key.value
    }
  }

  network {
    public = false
    private {
      ip = each.value.private_ip
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
    ignore_changes = [user_data]
  }

  depends_on = [
    terraform_data.validate_image,
    terraform_data.validate_flavors,
    ovh_cloud_gateway.kube_api,
  ]
}

### 
### Topology Dynamic: Catch the ips
###
resource "time_sleep" "wait_instance_networks" {
  for_each = local.public_vms_map

  create_duration = "30s"

  triggers = {
    instance_id = ovh_cloud_project_instance.vms[each.key].id
  }
}

data "ovh_cloud_project_instance" "vms" {
  # Keep keys static so OpenTofu can evaluate this data source during import
  # and partial-state recovery. Instance IDs remain apply-time values.
  for_each = local.public_vms_map

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  instance_id  = ovh_cloud_project_instance.vms[each.key].id
}

locals {
  # Public IPv4 from resource state. Existing instances stay known during plans
  # that add new VMs, unlike the OVH data source which is deferred when the
  # instance collection has pending changes.
  vm_public_ipv4_addresses = {
    for name, instance in ovh_cloud_project_instance.vms :
    name => try(one([
      for addr in instance.addresses : addr.ip
      if addr.version == 4 && addr.ip != local.all_vms_map[name].private_ip
    ]), null)
  }

  # Public IPv4 re-read after the network wait, used only for validation so new
  # instances get a chance to publish their public IP before checks run.
  vm_public_ipv4_addresses_after_wait = {
    for name, instance in data.ovh_cloud_project_instance.vms :
    name => try(one([
      for addr in instance.addresses : addr.ip
      if addr.version == 4 && addr.ip != local.all_vms_map[name].private_ip
    ]), null)
  }

  # Private IPv4: already known from the deterministic cidrhost assignment.
  vm_private_ipv4_addresses = { for name, vm in local.all_vms_map : name => vm.private_ip }

  # Names of public-attached VMs whose public IPv4 the OVH API has not (yet) returned.
  # Used by the precondition below to fail with a clear message instead
  # of letting compact() silently drop nodes from the Ansible inventory.
  vms_missing_public_ip = [
    for name, ip in local.vm_public_ipv4_addresses_after_wait :
    name if local.all_vms_map[name].public_attach && ip == null
  ]
}

# Fail fast if any public-attached VM is missing a public IPv4 after the
# wait_instance_networks delay. Without this, compact() in output.tf would
# silently exclude the VM from the generated Ansible inventory and apply would
# "succeed" with a broken hosts.ini.
resource "terraform_data" "validate_public_ips" {
  input = local.vm_public_ipv4_addresses_after_wait

  lifecycle {
    precondition {
      condition = length(local.vms_missing_public_ip) == 0
      error_message = format(
        "OVH did not publish a public IPv4 for the following VMs within %s: [%s]. Re-run apply (the OVH API is sometimes slow) or increase time_sleep.wait_instance_networks.create_duration.",
        "30s",
        join(", ", local.vms_missing_public_ip),
      )
    }
  }

  depends_on = [
    time_sleep.wait_instance_networks,
    data.ovh_cloud_project_instance.vms,
  ]
}

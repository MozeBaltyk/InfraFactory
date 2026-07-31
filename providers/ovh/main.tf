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
    var.infra.workers.instance_size
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
  for_each = local.all_vms_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"

  name      = each.value.name
  user_data = module.cloudinit.rendered[each.key]

  boot_from {
    image_id = local.selected_image.id
  }

  flavor {
    flavor_id = local.flavor_map[each.value.instance_size].id
  }

  ssh_key {
    name = ovh_cloud_project_ssh_key.cluster.name
  }

  network {
    public = true

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

  depends_on = [
    terraform_data.validate_image,
    terraform_data.validate_flavors
  ]
}

### 
### Topology Dynamic: Catch the ips
###
resource "time_sleep" "wait_instance_networks" {
  depends_on = [
    ovh_cloud_project_instance.vms
  ]

  create_duration = "15s"
}

data "ovh_cloud_project_instance" "vms" {
  for_each = ovh_cloud_project_instance.vms

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  instance_id  = each.value.id

  depends_on = [
    time_sleep.wait_instance_networks
  ]
}

locals {
  # Public IPv4: any IPv4 that is NOT the known private IP of that VM.
  vm_public_ipv4_addresses = {
    for name, instance in data.ovh_cloud_project_instance.vms :
    name => try(one([
      for addr in instance.addresses : addr.ip
      if addr.version == 4 && addr.ip != local.all_vms_map[name].private_ip
    ]), null)
  }

  # Private IPv4: already known from the deterministic cidrhost assignment.
  vm_private_ipv4_addresses = {
    for name, vm in local.all_vms_map :
    name => vm.private_ip
  }
}

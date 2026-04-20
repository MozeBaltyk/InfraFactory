### Pool
resource "libvirt_pool" "factory_pool" {
  name = var.cluster.id
  type = "dir"
  path = local.factory_pool_path
}

### Disks

# Fetch the OS image
resource "libvirt_volume" "os_image" {
  name   = "${local.os.os_name}${local.os.os_version_short}-os_image"
  pool   = libvirt_pool.factory_pool.name
  source = local.os.os_URL
  format = "qcow2"
}

resource "libvirt_volume" "resized_os_image" {

  for_each = local.all_vms_map

  name = "${each.value.name}-disk01.qcow2"

  base_volume_id = libvirt_volume.os_image.id
  pool           = libvirt_pool.factory_pool.name

  size = each.value.disk_size * 1024 * 1024 * 1024
}

resource "libvirt_volume" "extra_disks" {
  for_each = local.vm_disks_flat

  name = "${each.value.vm_name}-disk0${each.value.index + 2}.qcow2"
  pool = libvirt_pool.factory_pool.name
  size = each.value.size_gb * 1024 * 1024 * 1024
}

### Network
resource "null_resource" "network_validation" {
  lifecycle {
    precondition {
      condition = (
        var.network.ip_type == "dhcp" ||
        (
          length(var.infra.masters.ip_addresses) >= var.infra.masters.count &&
          length(var.infra.workers.ip_addresses) >= var.infra.workers.count
        )
      )
      error_message = "Static IP mode requires enough IP addresses for all VMs."
    }
  }
}

resource "libvirt_network" "network" {
  count = var.network.mode == "bridge" ? 0 : 1

  name      = var.cluster.id
  mode      = var.network.mode
  autostart = true

  # Set domain or addresses only for NAT/Route
  domain    = (var.network.mode == "nat" || var.network.mode == "route") ? local.subdomain : null
  addresses = (var.network.mode == "nat" || var.network.mode == "route") ? [var.network.cidr] : null

  # DHCP enabled only for NAT/Route and dhcp type
  dhcp {
    enabled = var.network.ip_type == "dhcp" && (var.network.mode == "nat" || var.network.mode == "route")
  }

  # DNS always enabled
  dns {
    enabled = true
  }

}

### VM Nodes
resource "libvirt_domain" "vms" {

  for_each = local.all_vms_map

  name   = each.value.name
  memory = each.value.memory_mb
  vcpu   = each.value.cpu

  autostart  = true
  qemu_agent = true

  disk {
    volume_id = libvirt_volume.resized_os_image[each.key].id
  }

  dynamic "disk" {
    for_each = local.vm_disks[each.key]

    content {
      volume_id = libvirt_volume.extra_disks["${each.key}-${disk.value.index}"].id

      scsi = true
      wwn  = disk.value.wwn
    }
  }

  network_interface {
    network_id     = var.network.mode == "bridge" ? null : libvirt_network.network[0].id
    bridge         = var.network.mode == "bridge" ? var.network.bridge_name : null
    wait_for_lease = var.network.mode == "bridge" ? false : var.network.ip_type == "dhcp"
    mac            = each.value.mac
  }

  cloudinit = libvirt_cloudinit_disk.commoninit[each.key].id

  cpu = {
    mode = "host-passthrough"
  }

  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  provisioner "remote-exec" {

    inline = [
      "echo 'Waiting for cloud-init to complete...'",
      "cloud-init status --wait > /dev/null",
      "echo 'Completed cloud-init!'"
    ]

    connection {
      type = "ssh"
      host = coalesce(
        each.value.ip,
        try(element([
          for addr in self.network_interface[0].addresses :
          addr if can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$", addr))
        ], 0), null),
        local.vm_fqdns[each.key]
      )
      user        = var.cluster.username
      private_key = tls_private_key.global_key.private_key_pem
    }
  }
}

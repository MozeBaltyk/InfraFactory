### Pool
resource "libvirt_pool" "factory_pool" {
  name = var.cluster.id
  type = "dir"
  path = local.factory_pool_path
}

# Safeguard: libvirt provider may leave an existing dir pool inactive on refresh.
resource "null_resource" "pool_start" {
  triggers = {
    pool = libvirt_pool.factory_pool.name
    uri  = local.libvirt_uri
  }

  provisioner "local-exec" {
    command = <<EOT
if ! virsh --connect "${local.libvirt_uri}" pool-info "${libvirt_pool.factory_pool.name}" | grep -q "State:.*running"; then
  virsh --connect "${local.libvirt_uri}" pool-start "${libvirt_pool.factory_pool.name}"
fi
EOT
  }
}

### Disks

# Talos image is a raw .xz: download, decompress and convert to qcow2.
# The cache lives outside the libvirt pool: libvirtd creates the pool dir as root,
# so the tofu user could not write the downloaded image into it.
locals {
  talos_image_cache = "${path.module}/../../.cache/talos"
}

resource "null_resource" "talos_image" {
  count = local.is_talos ? 1 : 0

  triggers = {
    url  = data.talos_image_factory_urls.this[0].urls.disk_image
    path = local.talos_image_cache
  }

  provisioner "local-exec" {
    command = <<EOT
mkdir -p ${local.talos_image_cache}
DST=${local.talos_image_cache}/talos-metal-${var.talos.version}.qcow2
SRC=${local.talos_image_cache}/talos-metal-${var.talos.version}.raw
[ -f "$DST" ] || {
  curl -fsSLo "${local.talos_image_cache}/talos-metal-${var.talos.version}.raw.zst" ${data.talos_image_factory_urls.this[0].urls.disk_image} \
    && zstd -df "${local.talos_image_cache}/talos-metal-${var.talos.version}.raw.zst" \
    && qemu-img convert -f raw -O qcow2 "$SRC" "$DST" \
    && rm -f "$SRC"
}
EOT
  }
}

# Fetch the OS image
resource "libvirt_volume" "os_image" {
  name   = "${local.os.os_name}${local.os.os_version_short}-os_image"
  pool   = libvirt_pool.factory_pool.name
  source = local.is_talos ? "${local.talos_image_cache}/talos-metal-${var.talos.version}.qcow2" : local.os.os_URL
  format = "qcow2"

  depends_on = [null_resource.pool_start, null_resource.talos_image]
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

  depends_on = [libvirt_volume.os_image]
}

### Network
resource "null_resource" "network_validation" {
  lifecycle {
    precondition {
      condition = (
        var.network.ip_type == "dhcp" ||
        (
          length(var.infra.masters.ip_addresses) >= var.infra.masters.count &&
          length(var.infra.workers.ip_addresses) >= var.infra.workers.count &&
          length(var.infra.vms.ip_addresses) >= var.infra.vms.count
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
  qemu_agent = false # ponytail: no guest agent in Talos/k3s images; lease source covers NAT/dhcp

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

  cloudinit = local.is_talos ? null : libvirt_cloudinit_disk.commoninit[each.key].id

  cpu {
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
}

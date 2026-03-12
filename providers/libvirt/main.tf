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

  for_each = {
    for vm in concat(local.master_details, local.worker_details) :
    vm.name => vm
  }

  name = "${each.value.name}-disk01.qcow2"

  base_volume_id = libvirt_volume.os_image.id
  pool           = libvirt_pool.factory_pool.name

  size = var.infra.disk_size * 1024 * 1024 * 1024
}

### Network

resource "libvirt_network" "network" {

  name      = var.cluster.id
  mode      = "nat"
  autostart = true

  domain    = local.subdomain
  addresses = [var.network.cidr]

  dhcp {
    enabled = true
  }

  dns {
    enabled = true
  }
}

### Master Nodes

resource "libvirt_domain" "masters" {

  count = var.cluster.masters

  name   = "${local.master_details[count.index].name}.${local.subdomain}"
  memory = var.infra.memory_mb
  vcpu   = var.infra.cpu

  autostart  = true
  qemu_agent = true

  disk {
    volume_id = libvirt_volume.resized_os_image[
      local.master_details[count.index].name
    ].id
  }

  network_interface {
    network_id     = libvirt_network.network.id
    wait_for_lease = true
  }

  cloudinit = libvirt_cloudinit_disk.commoninit[
    local.master_details[count.index].name
  ].id

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
      type        = "ssh"
      host        = self.network_interface[0].addresses[0]
      user        = var.cluster.username
      private_key = tls_private_key.global_key.private_key_pem
    }
  }
}

### Worker Nodes

resource "libvirt_domain" "workers" {

  count = var.cluster.workers

  name   = "${local.worker_details[count.index].name}.${local.subdomain}"
  memory = var.infra.memory_mb
  vcpu   = var.infra.cpu

  autostart  = true
  qemu_agent = true

  disk {
    volume_id = libvirt_volume.resized_os_image[
      local.worker_details[count.index].name
    ].id
  }

  network_interface {
    network_id     = libvirt_network.network.id
    wait_for_lease = true
  }

  cloudinit = libvirt_cloudinit_disk.commoninit[
    local.worker_details[count.index].name
  ].id

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
      type        = "ssh"
      host        = self.network_interface[0].addresses[0]
      user        = var.cluster.username
      private_key = tls_private_key.global_key.private_key_pem
    }
  }
}
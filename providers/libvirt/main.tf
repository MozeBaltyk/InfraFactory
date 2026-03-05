### Pool
resource "libvirt_pool" "factory_pool" {
  name = var.pool
  type = "dir"
  target = {
    path = local.factory_pool_path
  }
}

### Disks
# Fetch the OS image from local storage
resource "libvirt_volume" "os_image" {
  name = "${var.selected_version}.qcow2"
  pool = libvirt_pool.factory_pool.name
  target = {
    format = {
      type = "qcow2"
    }
  }
  create = {
    content = {
      url = local.qcow2_image
    }
  }
}

# Define Libvirt network
resource "libvirt_network" "network" {
  name      = var.network_name
  autostart = true

  bridge = {
    name = "virbr8"
  }

  domain = {
    name = local.subdomain
  }

  ips = [
    {
      address = "192.168.100.1"
      prefix  = 24
      dhcp = {
        ranges = [
          { start = "192.168.100.100", end = "192.168.100.200" }
        ]
      }
    }
  ]
  # Optional: NAT forwarding to allow Internet access
  forward = {
    mode = "nat"
  }
}

# Create Master VMs
resource "libvirt_domain" "masters" {
  count       = var.masters_number
  name        = local.master_details[count.index].name
  memory      = var.memory_size
  memory_unit = "MiB"
  vcpu        = var.cpu_size
  autostart   = true
  type        = "kvm"

  os = {
    type = "hvm"
  }

  devices = {
    disks = [
      {
        source = {
          file = {
            file = libvirt_volume.os_image.path
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        file = {
          file = libvirt_cloudinit_disk.commoninit[local.master_details[count.index].name].path
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
      }
    ]
    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.network.name
          }
        }
      }
    ]
    graphics = [
      {
        spice = {
          listen = "0.0.0.0"
        }
      }
    ]

    graphics = [
      {
        spice = {
          autoport = true
        }
      }
    ]
    video = {
      type = "virtio"
    }

  }
}

# Create Worker VMs
resource "libvirt_domain" "workers" {
  count       = var.workers_number
  name        = local.worker_details[count.index].name
  memory      = var.memory_size
  memory_unit = "MiB"
  vcpu        = var.cpu_size
  autostart   = true
  type        = "kvm"

  os = {
    type = "hvm"
  }

  devices = {
    disks = [
      {
        source = {
          file = {
            file = libvirt_volume.os_image.path
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
      },
      {
        file = {
          file = libvirt_cloudinit_disk.commoninit[local.worker_details[count.index].name].path
        }
        target = {
          dev = "vdb"
          bus = "virtio"
        }
      }
    ]
    interfaces = [
      {
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = libvirt_network.network.name
          }
        }
      }
    ]
  }
}

cluster = {
  id                  = "test"
  domain              = "local"
  timezone            = "Europe/Paris"
  username            = "localadmin"
  cloud_init_selected = "k3s"
  factory_root_path   = "/srv"
  node_name_format    = "role"
}

infra = {
  masters = {
    count     = 1
    cpu       = 4
    disk_size = 20
    memory_gb = 16
    extra_disks = [
      { size_gb = 20, mount_path = "/data", filesystem = "ext4", label = "data" }
    ]
  }

  workers = {
    count       = 0
    cpu         = 2
    disk_size   = 20
    memory_gb   = 4
    extra_disks = []
  }
}

network = {
  cidr    = "192.168.101.0/24"
  mode    = "nat"
  ip_type = "dhcp"
}

os = {
  selected = "ubuntu24"
}

libvirt = {
  remote = true
  user   = "ubuntu"
  host   = "192.168.122.1"
  port   = 22
  system = "system"
}

# if cloud_init_selected=k3s
k3s = {
  etcd_enabled           = true
  traefik_enabled        = true
  servicelb_enabled      = true
  local_storage_enabled  = true
  metrics_server_enabled = true
}

bootstrap_artifacts_mode = "bootstrap"

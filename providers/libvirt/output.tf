output "master_ips" {
  value = [for m in libvirt_domain.masters : m.network_interface[0].addresses[1]]
}

output "worker_ips" {
  value = [for w in libvirt_domain.workers : w.network_interface[0].addresses[1]]
}

output "ansible_inventory" {
  value = local_file.ansible_inventory.filename
}

resource "local_file" "ansible_inventory" {
  content = templatefile("../../inventory/hosts.tpl",
    {
      controller_ips = [for m in libvirt_domain.masters : m.network_interface[0].addresses[1]],
      worker_ips     = [for w in libvirt_domain.workers : w.network_interface[0].addresses[1]]
    }
  )
  filename = "../../inventory/hosts.ini"
}
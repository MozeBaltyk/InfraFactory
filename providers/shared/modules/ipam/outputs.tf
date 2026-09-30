output "master_ips" {
  description = "Deterministic private IPs for master nodes, in index order"
  value       = local.master_ips
}

output "worker_ips" {
  description = "Deterministic private IPs for worker nodes, in index order"
  value       = local.worker_ips
}

output "vm_ips" {
  description = "Deterministic private IPs for managed extra VMs, in index order"
  value       = local.vm_ips
}

output "bastion_ip" {
  description = "Reserved bastion IP (last usable host of the CIDR), agreed by convention across stacks"
  value       = local.bastion_ip
}

output "bastion_hostnum" {
  description = "Host number of the reserved bastion IP within the CIDR"
  value       = local.bastion_hostnum
}

output "last_node_hostnum" {
  description = "Highest host number handed to a node; must stay below bastion_hostnum"
  value       = local.last_node_hostnum
}

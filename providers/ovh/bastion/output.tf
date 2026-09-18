output "name" {
  description = "Bastion VM name"
  value       = var.bastion.id
}

output "public_ip" {
  description = "Bastion public IPv4 (stable for the VM lifetime: no replacement on cluster attach from Phase 2 on)"
  value       = local.bastion_public_ipv4_address
}

output "private_ips" {
  description = "Bastion private IP per served cluster (shared reserved address per CIDR)"
  value = {
    for name in local.cluster_names_sorted :
    name => module.ipam[name].bastion_ip
  }
}

output "cluster_node_ips" {
  description = "Served node addresses per cluster (the SSH-jump allowlist)"
  value = {
    for name in local.cluster_names_sorted : name => concat(
      module.ipam[name].master_ips,
      module.ipam[name].worker_ips,
    )
  }
}

output "converge" {
  description = "Day-2 convergence inputs for the Ansible bastion_converge role (P4), fed via `tofu output -json converge`"
  value = {
    username = var.bastion.username
    host     = var.bastion.id
    nics = {
      for name in local.cluster_names_sorted : name => {
        iface   = local.cluster_ifaces[name]
        address = module.ipam[name].bastion_ip
        prefix  = split("/", var.clusters[name].cidr)[1]
      }
    }
    permit_open    = local.permit_open
    test_addresses = local.sshd_test_addresses
    admin_keys     = var.admin_public_keys
    cluster_keys   = local.cluster_public_keys
  }
}

output "ssh_command" {
  description = "Direct SSH command to the bastion (use the private key matching an authorized key)"
  value = format(
    "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes %s@%s",
    var.bastion.username,
    local.bastion_public_ipv4_address,
  )
}

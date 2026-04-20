output "bootstrap_ssh_private_key_pem" {
  description = "Bootstrap-mode SSH private key for cluster access."
  sensitive   = true
  value       = local.bootstrap_mode ? tls_private_key.global_key.private_key_pem : null
}

output "bootstrap_ssh_public_key_openssh" {
  description = "Bootstrap-mode SSH public key for cluster access."
  value       = local.bootstrap_mode ? tls_private_key.global_key.public_key_openssh : null
}

output "bootstrap_cluster_token" {
  description = "Bootstrap-mode generated cluster token."
  sensitive   = true
  value       = local.bootstrap_mode ? local.cluster_token : null
}

output "bootstrap_hosts_ini" {
  description = "Bootstrap-mode rendered inventory content."
  value       = local.bootstrap_mode ? local.rendered_ansible_inventory : null
}

output "bootstrap_ansible_cfg" {
  description = "Bootstrap-mode rendered ansible.cfg content."
  value       = local.bootstrap_mode ? local.rendered_ansible_config : null
}

output "bootstrap_kubeconfig_host" {
  description = "Bootstrap-mode preferred endpoint for kubeconfig retrieval."
  value       = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? local.vm_operator_endpoints[local.first_master_name] : null
}

output "bootstrap_kubeconfig_user" {
  description = "Bootstrap-mode SSH username for kubeconfig retrieval."
  value       = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? var.cluster.username : null
}

output "bootstrap_kubeconfig_remote_path" {
  description = "Bootstrap-mode remote kubeconfig path on the first master."
  value       = local.kubeconfig_remote_path
}

output "private_key_pem" {
  description = "SSH private key (PEM)"
  sensitive   = true
  value       = tls_private_key.global_key.private_key_pem
}

output "public_key_openssh" {
  description = "SSH public key (OpenSSH format)"
  value       = tls_private_key.global_key.public_key_openssh
}

output "cluster_token" {
  description = "K3s/RKE2 cluster token (provided or generated)"
  sensitive   = true
  value       = local.cluster_token
}

output "gitops_ssh_private_key_pem" {
  description = "GitOps-mode SSH private key (null when gitops_mode is false)"
  sensitive   = true
  value       = var.gitops_mode ? tls_private_key.global_key.private_key_pem : null
}

output "gitops_ssh_public_key_openssh" {
  description = "GitOps-mode SSH public key (null when gitops_mode is false)"
  value       = var.gitops_mode ? tls_private_key.global_key.public_key_openssh : null
}

output "gitops_cluster_token" {
  description = "GitOps-mode cluster token (null when gitops_mode is false)"
  sensitive   = true
  value       = var.gitops_mode ? local.cluster_token : null
}

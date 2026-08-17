output "gitops_ansible_cfg" {
  description = "GitOps-mode rendered ansible.cfg content."
  value       = var.gitops_mode ? local.rendered_ansible_config : null
}

output "gitops_hosts_ini" {
  description = "GitOps-mode rendered inventory content."
  value       = var.gitops_mode ? local.rendered_ansible_inventory : null
}

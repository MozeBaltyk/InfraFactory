output "kubeconfig_raw" {
  description = "Raw kubeconfig for the talos cluster."
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "talos_config" {
  description = "talosconfig for talosctl access."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

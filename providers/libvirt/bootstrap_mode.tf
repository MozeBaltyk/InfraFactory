variable "bootstrap_artifacts_mode" {
  description = "Artifact delivery mode: manual writes local files, bootstrap exposes outputs only."
  type        = string
  default     = "manual"

  validation {
    condition     = contains(["manual", "bootstrap"], var.bootstrap_artifacts_mode)
    error_message = "bootstrap_artifacts_mode must be either 'manual' or 'bootstrap'."
  }
}

locals {
  bootstrap_mode        = var.bootstrap_artifacts_mode == "bootstrap"
  write_local_artifacts = !local.bootstrap_mode

  kubeconfig_remote_path = (
    var.cluster.cloud_init_selected == "rke2" ? "/etc/rancher/rke2/rke2.yaml" : (
      var.cluster.cloud_init_selected == "k3s" ? "/etc/rancher/k3s/k3s.yaml" : null
    )
  )

  rendered_ansible_inventory = templatefile("../shared/inventory/hosts.tpl", {
    controller_ips = [
      for vm_name, vm in local.masters_map : local.vm_operator_endpoints[vm_name]
    ]

    worker_ips = [
      for vm_name, vm in local.workers_map : local.vm_operator_endpoints[vm_name]
    ]
  })

  rendered_ansible_config = <<-EOT
[defaults]
remote_user = ${var.cluster.username}
inventory =  ./hosts.ini
roles_path = ../../../ansible/roles
host_key_checking = false
display_skipped_hosts = false
deprecation_warnings = false
force_color       = True
stdout_callback   = yaml
private_key_file = ./.key.private
EOT
}

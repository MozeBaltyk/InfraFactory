locals {
  rendered_ansible_inventory = templatefile("${path.module}/../../inventory/hosts.tpl", {
    controller_ips = var.controller_ips
    worker_ips     = var.worker_ips
    vm_ips         = var.vm_ips
  })

  rendered_ansible_config = <<-EOT
[defaults]
remote_user = ${var.username}
inventory =  ./hosts.ini
roles_path = ../../../ansible/roles
host_key_checking = false
display_skipped_hosts = false
deprecation_warnings = false
force_color       = True
stdout_callback   = yaml
private_key_file = ./.key.private
EOT

  abs_env_path = abspath(var.env_path)
}

# Generate environment-specific ansible.cfg
resource "local_file" "ansible_config" {
  count = var.write_local_artifacts ? 1 : 0

  filename = "${var.env_path}/ansible.cfg"
  content  = local.rendered_ansible_config
}

# Generate environment-specific hosts.ini
resource "local_file" "ansible_inventory" {
  count = var.write_local_artifacts ? 1 : 0

  content  = local.rendered_ansible_inventory
  filename = "${var.env_path}/hosts.ini"
}

###
### Check cloud-init status on all nodes using Ansible (shared playbook)
###

resource "null_resource" "check_cloudinit" {
  count = var.cloudinit_check_enabled ? 1 : 0

  triggers = {
    abs_env_path = local.abs_env_path
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../../ansible/check_cloudinit.yml
EOT
  }

  depends_on = [
    local_file.ansible_inventory,
    local_file.ansible_config
  ]
}

###
### Reconcile kube-apiserver TLS SAN on first master (add public IP)
###

resource "null_resource" "reconcile_tls_san" {
  count = var.k8s_flow_enabled && contains(["k3s", "rke2"], var.cloud_init_selected) ? 1 : 0

  triggers = {
    abs_env_path        = local.abs_env_path
    kube_api_endpoint   = var.kube_api_endpoint
    cloud_init_selected = var.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../../ansible/reconciliate_tls.yml \
  --limit CONTROLLERS \
  -e cloud_init_selected=${self.triggers.cloud_init_selected} \
  -e kube_api_endpoint=${self.triggers.kube_api_endpoint}
EOT
  }

  depends_on = [
    null_resource.check_cloudinit
  ]
}

###
### Import kubeconfig using Ansible (shared playbook)
###

resource "null_resource" "fetch_kubeconfig" {
  count = var.k8s_flow_enabled && contains(["k3s", "rke2"], var.cloud_init_selected) ? 1 : 0

  triggers = {
    cluster_name        = var.cluster_id
    abs_env_path        = local.abs_env_path
    ssh_host            = var.ssh_host
    kube_api_endpoint   = var.kube_api_endpoint
    cloud_init_selected = var.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../../ansible/fetch_kubeconfig.yml \
  --limit controller1 \
  -e cloud_init_selected=${self.triggers.cloud_init_selected} \
  -e kube_api_endpoint=${self.triggers.kube_api_endpoint} \
  -e local_kubeconfig_path=${self.triggers.abs_env_path}/kubeconfig
EOT
  }

  provisioner "local-exec" {
    when = destroy

    command = "rm -f ${self.triggers.abs_env_path}/kubeconfig"
  }

  depends_on = [
    null_resource.reconcile_tls_san
  ]
}

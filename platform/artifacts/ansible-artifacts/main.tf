locals {
  rendered_ansible_inventory = templatefile("${path.module}/../../inventory/hosts.tpl", {
    controller_ips = var.controller_ips
    worker_ips     = var.worker_ips
    vm_ips         = var.vm_ips
    proxy_jump     = var.proxy_jump
  })

  ansible_ssh_common_args = var.proxy_jump == null ? "" : var.proxy_jump.common_args

  node_generation_trigger = length(var.node_generation) == 0 ? {} : {
    node_generation_sha256 = sha256(jsonencode(var.node_generation))
  }

  rendered_ansible_config = join("", [<<-EOT
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
    , var.proxy_jump == null ? "" : <<-EOT

[ssh_connection]
ssh_common_args = ${local.ansible_ssh_common_args}
EOT
  ])

  abs_env_path = abspath(var.env_path)
}

# Generate environment-specific ansible.cfg
resource "local_file" "ansible_config" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/ansible.cfg"
  content         = local.rendered_ansible_config
  file_permission = "0644"
}

# Generate environment-specific hosts.ini
resource "local_file" "ansible_inventory" {
  count = var.write_local_artifacts ? 1 : 0

  content         = local.rendered_ansible_inventory
  filename        = "${var.env_path}/hosts.ini"
  file_permission = "0644"
}

###
### Check cloud-init status on all nodes using Ansible (shared playbook)
###

resource "null_resource" "check_cloudinit" {
  count = var.cloudinit_check_enabled ? 1 : 0

  triggers = merge({
    abs_env_path     = local.abs_env_path
    inventory_sha256 = sha256(local.rendered_ansible_inventory)
  }, local.node_generation_trigger)

  provisioner "local-exec" {
    command = "ansible-playbook \"$PLAYBOOK\""

    environment = {
      ANSIBLE_CONFIG = "${self.triggers.abs_env_path}/ansible.cfg"
      PLAYBOOK       = abspath("${path.module}/../../ansible/check_cloudinit.yml")
    }
  }

  depends_on = [
    local_file.ansible_inventory,
    local_file.ansible_config,
  ]
}

###
### Reconcile kube-apiserver TLS SAN on first master (add public IP)
###

resource "null_resource" "reconcile_tls_san" {
  count = var.k8s_flow_enabled && contains(["k3s", "rke2"], var.cloud_init_selected) ? 1 : 0

  triggers = merge({
    abs_env_path        = local.abs_env_path
    kube_api_endpoint   = var.kube_api_endpoint
    cloud_init_selected = var.cloud_init_selected
  }, local.node_generation_trigger)

  provisioner "local-exec" {
    command = "ansible-playbook \"$PLAYBOOK\" --limit CONTROLLERS --extra-vars \"$EXTRA_VARS\""

    environment = {
      ANSIBLE_CONFIG = "${self.triggers.abs_env_path}/ansible.cfg"
      PLAYBOOK       = abspath("${path.module}/../../ansible/reconciliate_tls.yml")
      EXTRA_VARS = jsonencode({
        cloud_init_selected = self.triggers.cloud_init_selected
        kube_api_endpoint   = self.triggers.kube_api_endpoint
      })
    }
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

  triggers = merge({
    cluster_name        = var.cluster_id
    abs_env_path        = local.abs_env_path
    ssh_host            = var.ssh_host
    kube_api_endpoint   = var.kube_api_endpoint
    cloud_init_selected = var.cloud_init_selected
  }, local.node_generation_trigger)

  provisioner "local-exec" {
    command = "ansible-playbook \"$PLAYBOOK\" --limit controller1 --extra-vars \"$EXTRA_VARS\""

    environment = {
      ANSIBLE_CONFIG = "${self.triggers.abs_env_path}/ansible.cfg"
      PLAYBOOK       = abspath("${path.module}/../../ansible/fetch_kubeconfig.yml")
      EXTRA_VARS = jsonencode({
        cloud_init_selected   = self.triggers.cloud_init_selected
        kube_api_endpoint     = self.triggers.kube_api_endpoint
        local_kubeconfig_path = "${self.triggers.abs_env_path}/kubeconfig"
      })
    }
  }

  provisioner "local-exec" {
    when = destroy

    command = "rm -f -- \"$KUBECONFIG_PATH\""

    environment = {
      KUBECONFIG_PATH = "${self.triggers.abs_env_path}/kubeconfig"
    }
  }

  depends_on = [
    null_resource.reconcile_tls_san
  ]
}

###
### Check cloud-init status on all nodes using Ansible (shared playbook)
###

resource "null_resource" "check_cloudinit" {
  count = 1

  triggers = {
    abs_env_path = abspath(local.env_path)
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../shared/ansible/check_cloudinit.yml
EOT
  }

  depends_on = [
    ovh_cloud_project_instance.vms,
    data.ovh_cloud_project_instance.vms,
    local_file.ansible_inventory,
    local_file.ansible_config
  ]
}

###
### Reconcile kube-apiserver TLS SAN on first master (add public IP)
###

resource "null_resource" "reconcile_tls_san" {
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? 1 : 0

  triggers = {
    abs_env_path        = abspath(local.env_path)
    kube_api_endpoint   = local.public_kube_api_endpoint
    cloud_init_selected = var.cluster.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../shared/ansible/reconciliate_tls.yml \
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
  count = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) ? 1 : 0

  triggers = {
    cluster_name              = var.cluster.id
    abs_env_path              = abspath(local.env_path)
    ssh_host                  = local.vm_public_ipv4_addresses[local.first_master_name]
    kube_api_endpoint         = local.public_kube_api_endpoint
    cloud_init_selected       = var.cluster.cloud_init_selected
  }

  provisioner "local-exec" {
    command = <<EOT
ANSIBLE_CONFIG=${self.triggers.abs_env_path}/ansible.cfg \
ansible-playbook \
  ${path.module}/../shared/ansible/fetch_kubeconfig.yml \
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



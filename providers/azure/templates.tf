# Azure-specific template resources for VM provisioning
# 
# This file handles cloud-init and custom image provisioning for Azure VMs.
# Azure uses user_data scripts attached to VM creation instead of ISO templates.
# 
# Template variables are rendered from cloud-init/*/cloud_init.cfg.tftpl
# and passed to azurerm_linux_virtual_machine.custom_data field.

# Cloud-init templates for master nodes
data "template_file" "master_cloudinit" {
  count = var.cluster.masters

  template = file("${path.module}/../../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl")

  vars = {
    timezone = var.cluster.timezone
    hostname = "${var.cluster.id}-master-${count.index}"
    fqdn = "${var.cluster.id}-master-${count.index}.${var.cluster.domain}"
    node_username = var.cluster.username
    public_key = tls_private_key.global_key.public_key_openssh
    k3s_token = "factory-token"
    first_master_fqdn = "${var.cluster.id}-master-0.${var.cluster.domain}"
    k3s_version = "v1.28.0+k3s1"
    k3s_etcd_enabled = count.index == 0 ? "true" : "false"
    k3s_traefik_enabled = "false"
    k3s_servicelb_enabled = "false"
    k3s_local_storage_enabled = "true"
    k3s_metrics_server_enabled = "true"
  }
}

# Cloud-init templates for worker nodes
data "template_file" "worker_cloudinit" {
  count = var.cluster.workers

  template = file("${path.module}/../../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl")

  vars = {
    timezone = var.cluster.timezone
    hostname = "${var.cluster.id}-worker-${count.index}"
    fqdn = "${var.cluster.id}-worker-${count.index}.${var.cluster.domain}"
    node_username = var.cluster.username
    public_key = tls_private_key.global_key.public_key_openssh
    k3s_token = "factory-token"
    first_master_fqdn = "${var.cluster.id}-master-0.${var.cluster.domain}"
    k3s_version = "v1.28.0+k3s1"
    k3s_etcd_enabled = "false"
    k3s_traefik_enabled = "false"
    k3s_servicelb_enabled = "false"
    k3s_local_storage_enabled = "true"
    k3s_metrics_server_enabled = "true"
  }
}

# Reserved for future Azure image/template definitions
# Following provider symmetry pattern with libvirt/templates.tf

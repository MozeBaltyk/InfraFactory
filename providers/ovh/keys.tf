###
### SSH
###

# Ensure environment directory exists
resource "null_resource" "env_directory" {
  provisioner "local-exec" {
    command = "mkdir -p ${local.env_path}"
  }
}

resource "local_file" "env_directory_placeholder" {
  filename = "${local.env_path}/.keep"
  content  = ""

  depends_on = [null_resource.env_directory]
}

resource "tls_private_key" "global_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_public_key" {
  filename = "${local.env_path}/.key.pub"
  content  = tls_private_key.global_key.public_key_openssh

  depends_on = [null_resource.env_directory]
}

resource "local_sensitive_file" "ssh_private_key" {
  filename        = "${local.env_path}/.key.private"
  content         = tls_private_key.global_key.private_key_pem
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}

# Push the key to OVH so it can be injected into the VMs
resource "ovh_cloud_project_ssh_key" "cluster" {
  service_name = var.ovh_project_service_name
  name         = "${var.cluster.id}-${terraform.workspace}"
  public_key   = trimspace(tls_private_key.global_key.public_key_openssh)
}

### 
### K8S Cluster Join Token
### 

resource "random_string" "cluster_token" {
  length           = 32
  special          = true
  override_special = "-_"
}

locals {
  selected_token = var.cluster.cloud_init_selected == "rke2" ? var.rke2.token : var.k3s.token
  cluster_token  = local.selected_token != null && local.selected_token != "" ? local.selected_token : random_string.cluster_token.result
}

resource "local_file" "cluster_token" {
  filename        = "${local.env_path}/.token"
  content         = local.cluster_token
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}

###
### SSH
###

# Ensure environment directory exists
resource "null_resource" "env_directory" {
  provisioner "local-exec" {
    command = "mkdir -p ${local.local_env_path}"
  }
}

# Generate an SSH key pair
resource "tls_private_key" "global_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save the public key to a local file
resource "local_file" "ssh_public_key" {
  filename = "${local.local_env_path}/.key.pub"
  content  = tls_private_key.global_key.public_key_openssh

  depends_on = [null_resource.env_directory]
}

# Save the private key to a local file
resource "local_sensitive_file" "ssh_private_key" {
  filename = "${local.local_env_path}/.key.private"
  content = tls_private_key.global_key.private_key_pem
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}

# Generate a random token for K3s/RKE2 if not provided via variables
resource "random_string" "cluster_token" {
  length  = 32
  special = true
  override_special = "-_"
}

locals {
  selected_token = var.cluster.cloud_init_selected == "rke2" ? var.rke2.token : var.k3s.token
  cluster_token  = local.selected_token != null && local.selected_token != "" ? local.selected_token : "${random_string.cluster_token.result}"
}

resource "local_file" "cluster_token" {
  filename = "${local.local_env_path}/.token"
  content  = local.cluster_token
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}
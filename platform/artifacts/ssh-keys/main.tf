# Ensure the environment directory exists
resource "null_resource" "env_directory" {
  count = var.write_local_artifacts ? 1 : 0

  provisioner "local-exec" {
    command = "mkdir -p -- \"$ENV_PATH\""

    environment = {
      ENV_PATH = abspath(var.env_path)
    }
  }
}

# Generate the SSH key pair
resource "tls_private_key" "global_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save the public key to a local file
resource "local_file" "ssh_public_key" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/.key.pub"
  content         = tls_private_key.global_key.public_key_openssh
  file_permission = "0644"

  depends_on = [null_resource.env_directory]
}

# Save the private key to a local file
resource "local_sensitive_file" "ssh_private_key" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/.key.private"
  content         = tls_private_key.global_key.private_key_pem
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}

# Cluster token: use the provided one, else generate a random one
resource "random_string" "cluster_token" {
  length           = 32
  special          = true
  override_special = "-_"
}

locals {
  selected_token = var.cloud_init_selected == "rke2" ? var.rke2_token : var.k3s_token
  cluster_token  = local.selected_token != null && local.selected_token != "" ? local.selected_token : random_string.cluster_token.result
}

# Write the cluster token to a local file
resource "local_file" "cluster_token" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/.token"
  content         = local.cluster_token
  file_permission = "0600"

  depends_on = [null_resource.env_directory]
}

locals {
  controlplane_nodes = [for node in var.nodes : node.endpoint if node.role == "master"]
  worker_nodes       = [for node in var.nodes : node.endpoint if node.role == "worker"]
  all_node_endpoints = [for node in var.nodes : node.endpoint]
}

# Cluster identity and TLS bootstrap secrets
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Generate the talosconfig (for talosctl) with endpoints/nodes baked in
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.controlplane_nodes
  nodes                = local.all_node_endpoints
}

# Per-role machine configuration (controlplane / worker)
data "talos_machine_configuration" "this" {
  for_each = toset(["controlplane", "worker"])

  cluster_name     = var.cluster_name
  cluster_endpoint = "https://${var.kube_api_endpoint}:6443"
  machine_type     = each.value
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version

  config_patches = var.config_patches
}

# Apply the machine configuration to each node (installs Talos and joins the cluster)
resource "talos_machine_configuration_apply" "this" {
  for_each = var.nodes

  node                        = each.value.endpoint
  endpoint                    = each.value.endpoint
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.value.role == "master" ? "controlplane" : "worker"].machine_configuration
}

# Bootstrap the etcd cluster on the first master
resource "talos_machine_bootstrap" "this" {
  node                 = var.first_master_node
  endpoint             = var.first_master_node
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.this
  ]
}

# Wait for the cluster to be healthy before exposing the kubeconfig
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.controlplane_nodes
  worker_nodes         = local.worker_nodes
  endpoints            = local.controlplane_nodes

  timeouts = {
    read = "20m"
  }

  depends_on = [
    talos_machine_bootstrap.this
  ]
}

# Fetch the cluster kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = var.first_master_node
  endpoint             = var.first_master_node

  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_health.this
  ]
}

# Write the kubeconfig to the environment directory (same path/name as k3s/rke2)
resource "local_sensitive_file" "talos_kubeconfig" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/kubeconfig"
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission = "0600"
}

# Write the talosconfig to the environment directory (for talosctl)
resource "local_sensitive_file" "talos_config" {
  count = var.write_local_artifacts ? 1 : 0

  filename        = "${var.env_path}/talosconfig"
  content         = data.talos_client_configuration.this.talos_config
  file_permission = "0600"
}

###
### Talos Linux cluster provisioning (experimental)
###
### Replaces the cloud-init + Ansible layer: nodes boot the Talos metal image into
### maintenance mode, the talos provider applies the machine configuration (which
### installs Talos to disk), bootstraps the cluster and returns the kubeconfig.
###
### Only active when cluster.cloud_init_selected == "talos".
###

# Build the metal image download URL from the Talos Factory (schematic + version)
data "talos_image_factory_urls" "this" {
  count         = local.is_talos ? 1 : 0
  talos_version = var.talos.version
  schematic_id  = var.talos.schematic_id
  platform      = "metal"
}

# Cluster identity and TLS bootstrap secrets
resource "talos_machine_secrets" "this" {
  count         = local.is_talos ? 1 : 0
  talos_version = var.talos.version
}

# Generate the talosconfig (for talosctl) with endpoints/nodes baked in
data "talos_client_configuration" "this" {
  count = local.is_talos ? 1 : 0

  cluster_name         = var.cluster.id
  client_configuration = talos_machine_secrets.this[0].client_configuration
  endpoints            = local.talos_controlplane_endpoints
  nodes                = [for vm_name, vm in local.all_vms_map : local.vm_operator_endpoints[vm_name]]
}

# Per-role machine configuration (controlplane / worker)
data "talos_machine_configuration" "this" {
  for_each = local.is_talos ? toset(["controlplane", "worker"]) : toset([])

  cluster_name     = var.cluster.id
  cluster_endpoint = "https://${local.kube_api_endpoint}:6443"
  machine_type     = each.value
  machine_secrets  = talos_machine_secrets.this[0].machine_secrets
  talos_version    = var.talos.version

  config_patches = [
    # Install onto the virtio boot disk (default is /dev/sda which does not exist on libvirt)
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda"
        }
      }
    })
  ]
}

# Apply the machine configuration to each node (installs Talos and joins the cluster)
resource "talos_machine_configuration_apply" "this" {
  for_each = local.is_talos ? local.all_vms_map : {}

  node                        = local.vm_operator_endpoints[each.key]
  endpoint                    = local.vm_operator_endpoints[each.key]
  client_configuration        = talos_machine_secrets.this[0].client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.value.role == "master" ? "controlplane" : "worker"].machine_configuration

  depends_on = [
    libvirt_domain.vms
  ]
}

# Bootstrap the etcd cluster on the first master
resource "talos_machine_bootstrap" "this" {
  count                = local.is_talos ? 1 : 0
  node                 = local.vm_operator_endpoints[local.first_master_name]
  endpoint             = local.vm_operator_endpoints[local.first_master_name]
  client_configuration = talos_machine_secrets.this[0].client_configuration

  depends_on = [
    talos_machine_configuration_apply.this
  ]
}

# Wait for the cluster to be healthy before exposing the kubeconfig
data "talos_cluster_health" "this" {
  count = local.is_talos ? 1 : 0

  client_configuration = talos_machine_secrets.this[0].client_configuration
  control_plane_nodes  = local.talos_controlplane_endpoints
  worker_nodes = [
    for vm_name, vm in local.all_vms_map :
    local.vm_operator_endpoints[vm_name] if vm.role == "worker"
  ]
  endpoints = local.talos_controlplane_endpoints

  timeouts = {
    read = "20m"
  }

  depends_on = [
    talos_machine_bootstrap.this
  ]
}

# Fetch the cluster kubeconfig
resource "talos_cluster_kubeconfig" "this" {
  count                = local.is_talos ? 1 : 0
  client_configuration = talos_machine_secrets.this[0].client_configuration
  node                 = local.vm_operator_endpoints[local.first_master_name]
  endpoint             = local.vm_operator_endpoints[local.first_master_name]

  depends_on = [
    talos_machine_bootstrap.this,
    data.talos_cluster_health.this
  ]
}

# Write the kubeconfig to the environment directory (same path/name as k3s/rke2)
resource "local_sensitive_file" "talos_kubeconfig" {
  count = local.is_talos && local.write_local_artifacts ? 1 : 0

  filename        = "${local.env_path}/kubeconfig"
  content         = talos_cluster_kubeconfig.this[0].kubeconfig_raw
  file_permission = "0600"

  depends_on = [
    module.ssh_keys
  ]
}

# Write the talosconfig to the environment directory (for talosctl)
resource "local_sensitive_file" "talos_config" {
  count = local.is_talos && local.write_local_artifacts ? 1 : 0

  filename        = "${local.env_path}/talosconfig"
  content         = data.talos_client_configuration.this[0].talos_config
  file_permission = "0600"

  depends_on = [
    module.ssh_keys
  ]
}

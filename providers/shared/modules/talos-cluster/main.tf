locals {
  # Cluster identity address per node: node_address when set, else the operator endpoint.
  resolved_node_addresses = {
    for name, node in var.nodes : name => coalesce(node.node_address, node.endpoint)
  }

  controlplane_nodes = [for node in var.nodes : node.endpoint if node.role == "master"]

  controlplane_node_addresses = [for name, node in var.nodes : local.resolved_node_addresses[name] if node.role == "master"]
  worker_node_addresses       = [for name, node in var.nodes : local.resolved_node_addresses[name] if node.role == "worker"]
  all_node_addresses          = [for name, node in var.nodes : local.resolved_node_addresses[name]]

  # Dial endpoint for post-bootstrap resources: the management endpoint (e.g. an
  # OVH LB floating IP) when set, else the direct controlplane endpoints.
  dial_endpoints = var.management_endpoint != null ? [var.management_endpoint] : local.controlplane_nodes

  # Resolved identity address of the bootstrap node (matched by operator endpoint).
  first_master_address = coalesce(
    one([for name, node in var.nodes : local.resolved_node_addresses[name] if node.endpoint == var.first_master_node]),
    var.first_master_node,
  )

  cni_patches = var.cni == null ? [] : [yamlencode({
    cluster = {
      network = {
        cni = {
          name = var.cni
        }
      }
    }
  })]

  scheduling_patches = var.allow_scheduling_on_control_planes == null ? [] : [yamlencode({
    cluster = {
      allowSchedulingOnControlPlanes = var.allow_scheduling_on_control_planes
    }
  })]

  extra_disk_patches = {
    for name, node in var.nodes : name => [
      for disk in node.extra_disks : yamlencode({
        apiVersion = "v1alpha1"
        kind       = "UserVolumeConfig"
        name       = disk.label
        volumeType = "disk"
        provisioning = {
          diskSelector = {
            match = "'/dev/disk/by-id/wwn-${disk.wwn}' in disk.symlinks"
          }
        }
        filesystem = {
          type = disk.filesystem
        }
      })
    ]
  }

  machine_config_patches = {
    for name, node in var.nodes : name => concat(
      var.config_patches,
      local.cni_patches,
      local.scheduling_patches,
      local.extra_disk_patches[name],
      node.role == "master" ? var.controlplane_config_patches : var.worker_config_patches,
      node.extra_patches,
    )
  }

  node_config_patches = {
    for name, node in var.nodes : name => [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = coalesce(node.hostname, name)
      auto       = "off"
    })]
  }
}

# Cluster identity and TLS bootstrap secrets
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Generate the talosconfig (for talosctl) with endpoints/nodes baked in
data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.dial_endpoints
  nodes                = local.all_node_addresses
}

# Per-node machine configuration (role config + stable hostname)
data "talos_machine_configuration" "this" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${var.kube_api_endpoint}:6443"
  machine_type       = each.value.role == "master" ? "controlplane" : "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = local.machine_config_patches[each.key]
}

# Apply the machine configuration to each node (installs Talos and joins the cluster)
# node = cluster identity (node_address/private IP) used for apid gRPC routing;
# endpoint = address to dial, which may differ (e.g. an SSH tunnel localhost port,
# a public IP, or the provider's operator endpoint).
resource "talos_machine_configuration_apply" "this" {
  for_each = var.nodes

  node                        = local.resolved_node_addresses[each.key]
  endpoint                    = each.value.endpoint
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.this[each.key].machine_configuration
  config_patches              = local.node_config_patches[each.key]
}

# Bootstrap the etcd cluster on the first master (dial var.first_master_node,
# identify the node as its resolved cluster address)
resource "talos_machine_bootstrap" "this" {
  node                 = local.first_master_address
  endpoint             = var.first_master_node
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [
    talos_machine_configuration_apply.this
  ]
}

# Wait for the cluster to be healthy before exposing the kubeconfig
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  control_plane_nodes  = local.controlplane_node_addresses
  worker_nodes         = local.worker_node_addresses
  endpoints            = local.dial_endpoints

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
  node                 = local.first_master_address
  endpoint             = var.management_endpoint != null ? var.management_endpoint : var.first_master_node

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

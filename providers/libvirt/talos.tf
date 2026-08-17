###
### Talos Linux cluster provisioning (experimental)
###
### Replaces the cloud-init + Ansible layer: nodes boot the Talos metal image into
### maintenance mode, the talos provider applies the machine configuration (which
### installs Talos to disk), bootstraps the cluster and returns the kubeconfig.
###
### Only active when cluster.cloud_init_selected == "talos".
###

# Build the metal image download URL from the Talos Factory (schematic + version).
# Image download/caching lives in main.tf (provider-side image provisioning).
data "talos_image_factory_urls" "this" {
  count         = local.is_talos ? 1 : 0
  talos_version = var.talos.version
  schematic_id  = var.talos.schematic_id
  platform      = "metal"
}

module "talos_cluster" {
  count  = local.is_talos ? 1 : 0
  source = "../shared/modules/talos-cluster"

  cluster_name       = var.cluster.id
  talos_version      = var.talos.version
  kubernetes_version = var.talos.kubernetes_version
  kube_api_endpoint  = local.kube_api_endpoint

  nodes = {
    for vm_name, vm in local.all_vms_map :
    vm_name => {
      endpoint    = local.vm_operator_endpoints[vm_name]
      role        = vm.role
      hostname    = vm.name
      extra_disks = local.vm_disks[vm_name]
    }
  }

  first_master_node = local.vm_operator_endpoints[local.first_master_name]

  # Install onto the virtio boot disk (default is /dev/sda which does not exist on libvirt)
  cni                                = var.talos.cni
  allow_scheduling_on_control_planes = var.talos.allow_scheduling_on_control_planes
  controlplane_config_patches        = var.talos.controlplane_config_patches
  worker_config_patches              = var.talos.worker_config_patches

  config_patches = concat([
    yamlencode({
      machine = {
        install = {
          disk = "/dev/vda"
        }
      }
    })
  ], var.talos.config_patches)

  env_path              = local.env_path
  write_local_artifacts = local.write_local_artifacts

  depends_on = [
    libvirt_domain.vms
  ]
}

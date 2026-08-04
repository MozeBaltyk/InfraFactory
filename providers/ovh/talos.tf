###
### Talos Linux cluster provisioning (experimental)
###
### Upload the Talos OpenStack image to Glance, then boot OVH instances from it.
###

locals {
  talos_openstack_image_name = coalesce(var.talos.image_name, "talos-${var.talos.version}")
  talos_openstack_image_url  = "https://factory.talos.dev/image/${var.talos.schematic_id}/${var.talos.version}/openstack-amd64.raw.xz"
  talos_openstack_cache_path = "${local.env_root}/.cache/talos-openstack"
}

module "talos_image" {
  count  = local.is_talos ? 1 : 0
  source = "../shared/modules/talos-ovh-image"

  name             = local.talos_openstack_image_name
  image_source_url = local.talos_openstack_image_url
  image_cache_path = local.talos_openstack_cache_path
  region           = var.cluster.region
}

resource "null_resource" "talos_env_directory" {
  count = local.is_talos ? 1 : 0

  provisioner "local-exec" {
    command = "mkdir -p ${local.env_path}"
  }
}

module "talos_cluster" {
  count  = local.is_talos ? 1 : 0
  source = "../shared/modules/talos-cluster"

  cluster_name       = var.cluster.id
  talos_version      = var.talos.version
  kubernetes_version = var.talos.kubernetes_version
  kube_api_endpoint  = local.public_kube_api_endpoint

  nodes = {
    for vm_name, vm in local.all_vms_map :
    vm_name => {
      endpoint    = local.vm_public_ipv4_addresses_after_wait[vm_name]
      role        = vm.role
      hostname    = vm.name
      extra_disks = []
    }
    if contains(["master", "worker"], vm.role)
  }

  first_master_node = local.vm_public_ipv4_addresses_after_wait[local.first_master_name]

  cni                                = var.talos.cni
  allow_scheduling_on_control_planes = var.talos.allow_scheduling_on_control_planes
  config_patches                     = var.talos.config_patches
  controlplane_config_patches        = var.talos.controlplane_config_patches
  worker_config_patches              = var.talos.worker_config_patches

  env_path = local.env_path

  depends_on = [
    null_resource.talos_env_directory,
    openstack_networking_secgroup_rule_v2.talos_private_ingress,
    openstack_networking_secgroup_rule_v2.talos_public_ingress,
    terraform_data.validate_public_ips,
  ]
}

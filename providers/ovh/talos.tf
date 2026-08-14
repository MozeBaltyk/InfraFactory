###
### Talos Linux cluster provisioning (experimental)
###
### Upload the Talos OpenStack image to Glance, then boot OVH instances from it.
###

locals {
  talos_openstack_image_name = coalesce(var.talos.image_name, "talos-${var.talos.version}")
  talos_openstack_image_url  = "https://factory.talos.dev/image/${var.talos.schematic_id}/${var.talos.version}/openstack-amd64.raw.xz"
  talos_openstack_cache_path = "${path.module}/../../.cache/talos-openstack"
  # OVH provider schema requires one key block, although Talos has no sshd.
  talos_ovh_placeholder_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOYHAAKJuAYmq2luBmUrzT3NCdqa5yKs8VVdWtse0jLl infrafactory-talos-unused"

  # The Talos OpenStack image uses kernel-style NIC names (eth0/eth1), not the
  # Ubuntu predictable names (ens3/ens4) used in the netplan overlay.
  # - Dual-NIC (non-jump): eth0 keeps DHCP with its default route; eth1 is
  #   static with NO default route so the Talos RouteSpecController never sees
  #   two gateways.
  # - Private-only (jump mode): eth0 is static with a default route via the
  #   private gateway (DHCP alone would hand out the private subnet's DNS,
  #   which cannot resolve public names); nameservers are pinned to OVH public
  #   DNS. Keys match the nodes passed to the talos-cluster module.
  ovh_talos_interface_patches = local.is_talos ? {
    for name, vm in local.all_vms_map : name => [yamlencode({
      machine = {
        network = {
          nameservers = ["213.186.33.99"]
          interfaces = concat(
            vm.public_attach ? [{
              interface = "eth0"
              dhcp      = true
            }] : [],
            vm.private_attach ? [vm.public_attach ? {
              interface = "eth1"
              addresses = ["${vm.private_ip}/${split("/", local.private_cidr)[1]}"]
              routes    = []
              } : {
              interface = "eth0"
              addresses = ["${vm.private_ip}/${split("/", local.private_cidr)[1]}"]
              routes = [{
                network = "0.0.0.0/0"
                gateway = local.private_gateway_ip
              }]
            }] : [],
          )
        }
      }
    })]
    if contains(["master", "worker"], vm.role)
  } : {}
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
    command = "mkdir -p -- \"$ENV_PATH\""

    environment = {
      ENV_PATH = abspath(local.env_path)
    }
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
      # Jump mode: dial the localhost SSH tunnel port; the cluster identity
      # stays the node's private IP. Non-jump dials the node's public IP.
      endpoint      = local.lb_ssh_jump_enabled ? local.talos_tunnel_endpoints[vm_name] : local.vm_public_ipv4_addresses_after_wait[vm_name]
      node_address  = vm.private_ip
      role          = vm.role
      hostname      = vm.name
      extra_disks   = []
      extra_patches = local.ovh_talos_interface_patches[vm_name]
    }
    if contains(["master", "worker"], vm.role)
  }

  first_master_node = local.lb_ssh_jump_enabled ? local.talos_tunnel_endpoints[local.first_master_name] : local.vm_public_ipv4_addresses_after_wait[local.first_master_name]

  # Post-bootstrap operations (talosconfig, health, kubeconfig) dial the LB
  # floating IP in non-jump mode. In jump mode they dial the per-node SSH
  # tunnel endpoints (127.0.0.1:<port>), so the talosconfig works through the
  # bastion tunnels; apply/bootstrap keep their direct per-node endpoints.
  management_endpoint = !local.lb_ssh_jump_enabled && local.lb_enabled ? local.lb_floating_ip_address : null

  cni                                = var.talos.cni
  allow_scheduling_on_control_planes = var.talos.allow_scheduling_on_control_planes
  config_patches                     = var.talos.config_patches
  # machine.certSANs feeds the kube-apiserver cert: workers and clients validate
  # it against the LB floating IP endpoint regardless of jump mode.
  controlplane_config_patches = concat(
    var.talos.controlplane_config_patches,
    local.lb_enabled ? [yamlencode({
      machine = {
        certSANs = [local.lb_floating_ip_address]
      }
    })] : [],
  )
  worker_config_patches = var.talos.worker_config_patches

  env_path = local.env_path

  depends_on = [
    null_resource.talos_env_directory,
    openstack_networking_port_secgroup_associate_v2.cluster_public,
    openstack_networking_port_secgroup_associate_v2.cluster_private,
    ovh_cloud_project_loadbalancer.kube_api,
    terraform_data.validate_public_ips,
    terraform_data.talos_tunnels, # dial endpoints ready when jump mode is active
  ]
}

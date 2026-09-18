### Derived cluster topology (locals) — inputs stay in variables.tf.
### Moved verbatim (no behavior change); see backlog item.

# Caller's current public IP, used below to auto-allow kube-api/SSH ingress
# for whoever is running `tofu apply` (see local.my_public_ip).
data "http" "my_ip" {
  count = local.kubernetes_enabled ? 1 : 0

  url = "http://ifconfig.me/ip"
}

locals {
  env_root = abspath("${path.module}/../../../env")
  env_path = "${local.env_root}/${var.infra_provider}/${terraform.workspace}"

  os = var.os_catalog[var.os.selected]

  subdomain = "${var.cluster.id}.${var.cluster.domain}"

  kubernetes_enabled = contains(["k3s", "rke2"], var.cluster.cloud_init_selected)

  # Auto-detected caller public IP, appended to the explicit
  # network.kube_api.ingress_cidrs below so the operator running `tofu
  # apply` doesn't lock themselves out; it never substitutes for an explicit
  # entry (see the validate_operator_ingress_cidrs precondition in checks.tf).
  my_public_ip = local.kubernetes_enabled ? "${chomp(trimspace(data.http.my_ip[0].response_body))}/32" : null

  ## Private handling (managed only: the cluster always owns its network)
  private_cidr                = var.network.private.cidr
  private_ip_host_offset_base = (tonumber(split("/", local.private_cidr)[1]) <= 28 ? 10 : 2)

  private_network_id = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  private_subnet_id  = ovh_cloud_project_network_private_subnet_v2.cluster.id
  private_gateway_ip = ovh_cloud_project_network_private_subnet_v2.cluster.gateway_ip

  ## Load Balancer
  # Kubernetes nodes are ALWAYS jump-mode (private-only, via the standalone
  # bastion): there is no public topology for k3s/rke2 on OVH anymore.
  # Enforced by the validate_k8s_topology preconditions in bastion.tf
  # (bastion set + LB enabled + lb_ip/dns endpoint); plain VM-only shapes
  # evaluate exactly as before.
  k8s_nodes  = local.kubernetes_enabled && var.infra.masters.count > 0
  lb_enabled = local.k8s_nodes && try(var.network.kube_api.load_balancer.enabled, false)
  # Standalone bastion addresses: public IP is the input, private IP is the
  # shared reserved address (last usable host of the CIDR, no shared state).
  bastion_public_ipv4_address = try(var.bastion.public_ip, null)
  bastion_private_ip          = module.ipam.bastion_ip
  lb_floating_ip_address      = try(ovh_cloud_floating_ip.kube_api[0].id, null)
  # Explicit CIDRs plus the caller's auto-detected current IP; deduplicated
  # in case the operator already listed it explicitly.
  kube_api_ingress_cidrs = distinct(concat(
    try(var.network.kube_api.ingress_cidrs, []),
    local.my_public_ip != null ? [local.my_public_ip] : [],
  ))
  # Workload ingress (80/443) audience: explicit per-LB override, else the
  # API audience. Never public-open by default.
  lb_ingress_cidrs = distinct(coalesce(
    try(var.network.kube_api.load_balancer.ingress_cidrs, null),
    try(var.network.kube_api.ingress_cidrs, []),
  ))
  lb_flavor_id = local.lb_enabled ? one([
    for f in data.ovh_cloud_project_loadbalancer_flavors.lb[0].flavors :
    f.id if f.name == var.network.kube_api.load_balancer.flavor
  ]) : null

  ## VM Topology Static
  master_details = [
    for i in range(var.infra.masters.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1)
        : format("%s-m%02d", var.cluster.id, i + 1)
      )
      role              = "master"
      instance_size     = var.infra.masters.instance_size
      disk_size         = var.infra.masters.disk_size
      extra_disks       = try(var.infra.masters.extra_disks, [])
      user_data_enabled = var.infra.masters.user_data_enabled
      private_ip        = module.ipam.master_ips[i]
      private_attach    = true
      public_attach     = !local.k8s_nodes
      nfs               = try(var.infra.masters.nfs, [])
      object_storage    = try(var.infra.masters.object_storage, [])
    }
  ]

  worker_details = [
    for i in range(var.infra.workers.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1 + var.infra.masters.count)
        : format("%s-w%02d", var.cluster.id, i + 1)
      )
      role              = "worker"
      instance_size     = var.infra.workers.instance_size
      disk_size         = var.infra.workers.disk_size
      extra_disks       = try(var.infra.workers.extra_disks, [])
      user_data_enabled = var.infra.workers.user_data_enabled
      private_ip        = module.ipam.worker_ips[i]
      private_attach    = true
      public_attach     = !local.k8s_nodes
      nfs               = try(var.infra.workers.nfs, [])
      object_storage    = try(var.infra.workers.object_storage, [])
    }
  ]

  masters_map = {
    for vm in local.master_details : vm.name => vm
  }

  workers_map = {
    for vm in local.worker_details : vm.name => vm
  }

  cluster_vms_map = merge(local.masters_map, local.workers_map)

  vm_details = [
    for i in range(var.infra.vms.count) : {
      name = (
        var.cluster.node_name_format == "serial"
        ? format("%s-node%02d", var.cluster.id, i + 1 + var.infra.masters.count + var.infra.workers.count)
        : format("%s-v%02d", var.cluster.id, i + 1)
      )
      role              = "vm"
      instance_size     = var.infra.vms.instance_size
      user_data_enabled = var.infra.vms.user_data_enabled
      private_ip        = module.ipam.vm_ips[i]
      private_attach    = true
      public_attach     = true
      nfs               = try(var.infra.vms.nfs, [])
      object_storage    = try(var.infra.vms.object_storage, [])
    }
  ]

  vms_map = {
    for vm in local.vm_details : vm.name => vm
  }

  all_vms_map = merge(local.masters_map, local.workers_map, local.vms_map)

  first_master_name = try(local.master_details[0].name, null)
  first_master_fqdn = local.first_master_name != null ? "${local.first_master_name}.${local.subdomain}" : null

  ## Kubernetes API bootstrap endpoint (first master private IP); overridden by LB when present
  kube_api_bootstrap_endpoint = try(local.master_details[0].private_ip, null)
  ## Public-facing API endpoint for kubeconfig. Kubernetes is jump-only:
  ## endpoint is validated to "lb_ip" (LB required) or "dns" (name required),
  ## so no public-IP or literal endpoint exists for private-only nodes.
  public_kube_api_endpoint = (
    var.network.kube_api.endpoint == "lb_ip" && local.lb_floating_ip_address != null
    ? local.lb_floating_ip_address
    : try(var.network.kube_api.dns.name, "")
  )

}

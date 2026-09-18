# P3: cluster points at the standalone bastion (own state). The embedded VM,
# SG, ports, and readiness check are gone; only the topology guard stays.
# Bastion addresses live in variables.tf (public IP = var.bastion input,
# private IP = module.ipam.bastion_ip convention, no shared state).

resource "terraform_data" "validate_ssh_jump_topology" {
  count = local.ssh_jump_requested ? 1 : 0

  lifecycle {
    precondition {
      condition = (
        !local.ssh_jump_requested ||
        (local.lb_enabled && var.network.kube_api.endpoint == "lb_ip")
      )
      error_message = "var.bastion requires an enabled load balancer with network.kube_api.endpoint = \"lb_ip\". K3s/RKE2 nodes are reached through the standalone bastion via a self-contained ProxyCommand."
    }
  }
}

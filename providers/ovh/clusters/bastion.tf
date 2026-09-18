# Jump-only Kubernetes: k3s/rke2 nodes are always private-only behind the
# standalone bastion. There is no public topology for Kubernetes on OVH —
# the guards below make bastion + LB mandatory, and every jump conditional
# elsewhere keys off local.k8s_nodes. Bastion addresses live in
# variables.tf (public IP = var.bastion input, private IP =
# module.ipam.bastion_ip convention, no shared state).

resource "terraform_data" "validate_k8s_topology" {
  count = local.k8s_nodes ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.bastion != null
      error_message = "Kubernetes modes require var.bastion = { public_ip }: K3s/RKE2 nodes are private-only and reachable solely through the standalone bastion."
    }

    precondition {
      condition     = local.lb_enabled
      error_message = "Kubernetes modes require network.kube_api.load_balancer.enabled = true: the API is served through the load balancer."
    }

    precondition {
      condition     = contains(["lb_ip", "dns"], var.network.kube_api.endpoint)
      error_message = "Kubernetes modes require network.kube_api.endpoint = \"lb_ip\" (or \"dns\" with dns.name set): no public-IP endpoint exists for private-only nodes."
    }
  }
}

###
### Private Network and Subnet
###

resource "ovh_cloud_project_network_private" "cluster" {
  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  vlan_id      = var.network.private.vlan_id
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  service_name                    = var.ovh_project_service_name
  network_id                      = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  region                          = var.cluster.region
  name                            = format("%s-subnet", var.cluster.id)
  cidr                            = local.private_cidr
  # Gateway is mandatory for lb with public floating IP (but not for private-only network).
  # dhcp                            = true
  enable_gateway_ip               = local.lb_enabled
  # use_default_public_dns_resolver = true
}

# The OVH provider's LB Delete does NOT cascade delete the gateway created by
# gateway_create. The gateway survives with its port on the subnet, blocking
# subnet deletion. This resource explicitly cleans up the gateway before the
# subnet is destroyed.
#
# Dependency chain (destroy order):
#   LB → VMs → private_network_destroy_grace (cleanup gateway) → subnet
# VMs depend on this resource so OpenTofu destroys them BEFORE this one.
resource "null_resource" "private_network_destroy_grace" {
  triggers = {
    network_id             = local.private_network_id
    subnet_id              = local.private_subnet_id
    gateway_name           = local.lb_enabled ? "${var.cluster.id}-gateway" : ""
    service_name            = var.ovh_project_service_name
    region                 = var.cluster.region
    ovh_endpoint           = var.ovh_endpoint
    ovh_application_key    = var.ovh_application_key
    ovh_application_secret = var.ovh_application_secret
    ovh_consumer_key       = var.ovh_consumer_key
  }

  provisioner "local-exec" {
    when = destroy

    environment = {
      OVH_ENDPOINT            = self.triggers.ovh_endpoint
      OVH_APPLICATION_KEY     = self.triggers.ovh_application_key
      OVH_APPLICATION_SECRET  = self.triggers.ovh_application_secret
      OVH_CONSUMER_KEY        = self.triggers.ovh_consumer_key
      OVH_SERVICE_NAME        = self.triggers.service_name
      OVH_REGION              = self.triggers.region
      OVH_GATEWAY_NAME            = self.triggers.gateway_name
    }

    command = <<-EOT
      if [ -z "$OVH_GATEWAY_NAME" ]; then
        exit 0
      fi
      # Prefer 'uv' when available: it runs the script in an ephemeral,
      # cached venv with the ovh package, requires no persistent install,
      # and side-steps PEP 668-protected system Pythons.
      if command -v uv >/dev/null 2>&1; then
        exec uv run --no-project --with ovh python3 "${path.module}/cleanup_gateway.py"
      fi
      # Fallback: rely on a system python3 that already has the ovh package.
      if ! command -v python3 >/dev/null 2>&1; then
        echo "ERROR: neither uv nor python3 is available for OVH destroy cleanup." >&2
        echo "       Install uv (https://docs.astral.sh/uv/) or Python 3, then retry destroy." >&2
        exit 1
      fi
      if ! python3 -c "import ovh" >/dev/null 2>&1; then
        echo "ERROR: the 'ovh' Python package is required for OVH destroy cleanup." >&2
        echo "       Either install 'uv' (recommended) or run 'pip install --user ovh'," >&2
        echo "       then retry destroy." >&2
        exit 1
      fi
      python3 "${path.module}/cleanup_gateway.py"
    EOT
  }

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

###
### Load Balancer for the Kubernetes API
###

data "ovh_cloud_project_loadbalancer_flavors" "lb" {
  count        = local.lb_enabled ? 1 : 0
  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
}

resource "ovh_cloud_project_loadbalancer" "kube_api" {
  count = local.lb_enabled ? 1 : 0

  service_name = var.ovh_project_service_name
  region_name  = var.cluster.region
  name         = "${var.cluster.id}-kube-api"
  flavor_id    = local.lb_flavor_id

  network = {
    private = {
      network = {
        id        = local.private_network_id
        subnet_id = local.private_subnet_id
      }
      gateway_create = {
        model = var.network.kube_api.load_balancer.gateway_model
        name  = "${var.cluster.id}-gateway"
      }
      floating_ip_create = {
        description = "${var.cluster.id}-kube-api-fip"
      }
    }
  }

  listeners = [
    {
      port     = 6443
      protocol = "tcp"
      name     = "kube-api"

      pool = {
        algorithm = "roundRobin"
        protocol  = "tcp"
        name      = "kube-api-pool"

        health_monitor = {
          name         = "${var.cluster.id}-kube-api-hm"
          delay        = 5
          max_retries  = 3
          timeout      = 3
          monitor_type = "tcp"
        }

        members = [
          for m in local.master_details : {
            address       = m.private_ip
            protocol_port = 6443
            weight        = 1
          }
        ]
      }
    }
  ]

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
    ovh_cloud_project_instance.vms
  ]
}
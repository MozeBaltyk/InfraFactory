###
### Private Network and Subnet
###

resource "ovh_cloud_project_network_private" "cluster" {
  count = local.private_network_managed ? 1 : 0

  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  vlan_id      = var.network.private.vlan_id
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  count = local.private_network_managed ? 1 : 0

  service_name = var.ovh_project_service_name
  network_id   = ovh_cloud_project_network_private.cluster[0].regions_openstack_ids[var.cluster.region]
  region       = var.cluster.region
  name         = format("%s-subnet", var.cluster.id)
  cidr         = local.private_cidr
  # Gateway is mandatory for lb with public floating IP (but not for private-only network).
  enable_gateway_ip               = local.lb_enabled
  use_default_public_dns_resolver = false
  # Private VM ports and guest netplan use deterministic static private IPs.
  dhcp = true
}

data "ovh_cloud_project_network_privates" "existing" {
  count = local.private_network_existing ? 1 : 0

  service_name = var.ovh_project_service_name
}

data "ovh_cloud_project_network_private_subnets" "existing" {
  count = local.private_network_existing && local.existing_private_network_global_id != null ? 1 : 0

  service_name = var.ovh_project_service_name
  network_id   = local.existing_private_network_global_id
}

resource "terraform_data" "validate_existing_private_network" {
  count = local.private_network_existing ? 1 : 0

  input = {
    vlan_id       = var.network.private.vlan_id
    cidr          = local.private_cidr
    region        = var.cluster.region
    network_count = length(local.existing_private_network_matches)
    subnet_count  = length(local.existing_private_subnet_matches)
  }

  lifecycle {
    precondition {
      condition     = length(local.existing_private_network_matches) == 1
      error_message = "network.private.mode = \"existing\" requires exactly one OVH private network matching network.private.vlan_id in cluster.region."
    }

    precondition {
      condition     = length(local.existing_private_subnet_matches) == 1
      error_message = "network.private.mode = \"existing\" requires exactly one OVH private subnet matching network.private.cidr on the discovered private network."
    }
  }
}

###
### OpenStack security group rules for public Kubernetes/Talos access
###

data "openstack_networking_secgroup_v2" "default" {
  count  = local.is_talos ? 1 : 0
  name   = "default"
  region = var.cluster.region
}

locals {
  talos_public_ingress_rules = local.is_talos ? merge(
    {
      for cidr in local.kube_api_ingress_cidrs : "talos-${cidr}" => {
        port = 50000
        cidr = cidr
      }
    },
    {
      for cidr in local.kube_api_ingress_cidrs : "kube-api-${cidr}" => {
        port = 6443
        cidr = cidr
      }
    }
  ) : {}
}

resource "openstack_networking_secgroup_rule_v2" "talos_public_ingress" {
  for_each = local.talos_public_ingress_rules

  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = each.value.cidr
  security_group_id = data.openstack_networking_secgroup_v2.default[0].id
  region            = var.cluster.region
}

resource "openstack_networking_secgroup_rule_v2" "talos_private_ingress" {
  count = local.is_talos ? 1 : 0

  direction         = "ingress"
  ethertype         = "IPv4"
  remote_ip_prefix  = local.private_cidr
  security_group_id = data.openstack_networking_secgroup_v2.default[0].id
  region            = var.cluster.region
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
  count = local.private_network_managed ? 1 : 0

  triggers = {
    network_id      = local.private_network_id
    subnet_id       = local.private_subnet_id
    gateway_name    = local.lb_enabled ? "${var.cluster.id}-gateway" : ""
    cluster_id      = var.cluster.id
    service_name    = var.ovh_project_service_name
    region          = var.cluster.region
    ovh_endpoint    = var.ovh_endpoint
    credential_hint = "Set OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, and OVH_CONSUMER_KEY in the environment before destroy."
  }

  provisioner "local-exec" {
    when = destroy

    environment = {
      OVH_ENDPOINT     = self.triggers.ovh_endpoint
      OVH_SERVICE_NAME = self.triggers.service_name
      OVH_REGION       = self.triggers.region
      OVH_GATEWAY_NAME = self.triggers.gateway_name
      OVH_CLUSTER_ID   = self.triggers.cluster_id
      OVH_SUBNET_ID    = self.triggers.subnet_id
    }

    command = <<-EOT
      if [ -z "$OVH_APPLICATION_KEY" ] || [ -z "$OVH_APPLICATION_SECRET" ] || [ -z "$OVH_CONSUMER_KEY" ]; then
        echo "ERROR: OVH destroy cleanup needs OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, and OVH_CONSUMER_KEY in the environment." >&2
        echo "       ${self.triggers.credential_hint}" >&2
        exit 1
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
### Capture and clean up LB floating IP at destroy time
###
# The OVH LB resource does NOT cascade-delete the floating IP when the LB is
# destroyed. This terraform_data holds the IP in self.input and runs a destroy
# provisioner BEFORE the LB is destroyed (because this resource depends on the
# LB, the destroy order is: capture → LB → ...). At that point self.input is
# still live, so no file handoff is needed. The destroy provisioner calls the
# cleanup script with OVH_FLOATING_IP set; OVH_GATEWAY_NAME and OVH_SUBNET_ID
# are absent, so the script skips gateway and subnet operations — those are
# handled by null_resource.private_network_destroy_grace later in the chain.
resource "terraform_data" "capture_lb_floating_ip" {
  count = local.lb_enabled ? 1 : 0

  input = {
    ip           = local.lb_floating_ip_address
    cluster_id   = var.cluster.id
    module_path  = abspath(path.module)
    ovh_endpoint = var.ovh_endpoint
    service_name = var.ovh_project_service_name
    region       = var.cluster.region
  }

  provisioner "local-exec" {
    when    = create
    command = "echo 'Floating IP ${self.input.ip} captured for cluster ${self.input.cluster_id}'"
  }

  provisioner "local-exec" {
    when = destroy

    environment = {
      OVH_ENDPOINT     = self.input.ovh_endpoint
      OVH_SERVICE_NAME = self.input.service_name
      OVH_REGION       = self.input.region
      OVH_FLOATING_IP  = self.input.ip
    }

    command = <<-EOT
      if [ -z "$OVH_APPLICATION_KEY" ] || [ -z "$OVH_APPLICATION_SECRET" ] || [ -z "$OVH_CONSUMER_KEY" ]; then
        echo "ERROR: OVH destroy floating-IP cleanup needs OVH_APPLICATION_KEY, OVH_APPLICATION_SECRET, and OVH_CONSUMER_KEY in the environment." >&2
        exit 1
      fi
      if command -v uv >/dev/null 2>&1; then
        exec uv run --no-project --with ovh python3 "${path.module}/cleanup_gateway.py"
      fi
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
    ovh_cloud_project_loadbalancer.kube_api,
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

  listeners = concat(
    [
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
    ],
    local.lb_ssh_jump_enabled ? [
      {
        port     = local.lb_ssh_jump_port
        protocol = "tcp"
        name     = "master-ssh-jump"

        pool = {
          algorithm = "roundRobin"
          protocol  = "tcp"
          name      = "master-ssh-jump-pool"

          health_monitor = {
            name         = "${var.cluster.id}-master-ssh-jump-hm"
            delay        = 5
            max_retries  = 3
            timeout      = 3
            monitor_type = "tcp"
          }

          members = [
            {
              address       = local.master_details[0].private_ip
              protocol_port = 22
              weight        = 1
            }
          ]
        }
      }
    ] : []
  )

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
    ovh_cloud_project_instance.vms
  ]
}

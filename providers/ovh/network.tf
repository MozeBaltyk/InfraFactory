###
### Private Network and Subnet
###

resource "ovh_cloud_project_network_private" "cluster" {
  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  regions      = [var.cluster.region]
}

resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  service_name                    = var.ovh_project_service_name
  network_id                      = ovh_cloud_project_network_private.cluster.regions_openstack_ids[var.cluster.region]
  region                          = var.cluster.region
  name                            = format("%s-subnet", var.cluster.id)
  cidr                            = local.private_cidr
  dhcp                            = true
  enable_gateway_ip               = true
  use_default_public_dns_resolver = true
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
    network_id              = local.private_network_id
    subnet_id               = local.private_subnet_id
    gateway_name            = local.lb_enabled ? "${var.cluster.id}-gateway" : ""
    service_name            = var.ovh_project_service_name
    region                  = var.cluster.region
    ovh_endpoint            = var.ovh_endpoint
    ovh_application_key     = var.ovh_application_key
    ovh_application_secret  = var.ovh_application_secret
    ovh_consumer_key        = var.ovh_consumer_key
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      GATEWAY_NAME="${self.triggers.gateway_name}"
      if [ -n "$GATEWAY_NAME" ]; then
        export OVH_ENDPOINT="${self.triggers.ovh_endpoint}"
        export OVH_APPLICATION_KEY="${self.triggers.ovh_application_key}"
        export OVH_APPLICATION_SECRET="${self.triggers.ovh_application_secret}"
        export OVH_CONSUMER_KEY="${self.triggers.ovh_consumer_key}"
        export OVH_SERVICE_NAME="${self.triggers.service_name}"
        export OVH_REGION="${self.triggers.region}"
        export OVH_GATEWAY_NAME="$GATEWAY_NAME"
        PYTHON=""
        for p in /tmp/ovh_venv/bin/python3 python3 python; do
          if command -v "$p" >/dev/null 2>&1; then
            if "$p" -c "import ovh" 2>/dev/null; then
              PYTHON="$p"
              break
            fi
          fi
        done
        if [ -z "$PYTHON" ]; then
          python3 -m venv /tmp/ovh_venv
          /tmp/ovh_venv/bin/pip install ovh -q
          PYTHON=/tmp/ovh_venv/bin/python3
        fi
        "$PYTHON" "${path.module}/cleanup_gateway.py"
      fi
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
        model = "s"
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
            address        = m.private_ip
            protocol_port  = 6443
            weight         = 1
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
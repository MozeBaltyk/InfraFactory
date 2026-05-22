###
### Private Network and Subnet if requested
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

resource "null_resource" "private_network_destroy_grace" {
  triggers = {
    network_id   = local.private_network_id
    subnet_id    = local.private_subnet_id
    wait_seconds = "20"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "sleep ${self.triggers.wait_seconds}"
  }

  depends_on = [
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

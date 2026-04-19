data "ovh_cloud_project_images" "os" {
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  os_type      = "linux"
}

data "ovh_cloud_project_flavors" "masters" {
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name_filter  = var.infra.masters.instance_size
}

data "ovh_cloud_project_flavors" "workers" {
  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name_filter  = var.infra.workers.instance_size
}

locals {
  master_image = one([
    for image in data.ovh_cloud_project_images.os.images : image
    if image.name == local.os.image.name && image.region == var.cluster.region
  ])

  master_flavor = one([
    for flavor in data.ovh_cloud_project_flavors.masters.flavors : flavor
    if flavor.name == var.infra.masters.instance_size && flavor.available
  ])

  worker_flavor = one([
    for flavor in data.ovh_cloud_project_flavors.workers.flavors : flavor
    if flavor.name == var.infra.workers.instance_size && flavor.available
  ])
}

resource "ovh_cloud_project_instance" "masters" {
  for_each = local.masters_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"
  name           = each.value.name
  user_data      = local.master_cloudinit[each.key]

  boot_from {
    image_id = local.master_image.id
  }

  flavor {
    flavor_id = local.master_flavor.id
  }

  ssh_key {
    name = ovh_cloud_project_ssh_key.cluster.name
  }

  network {
    public = true

    dynamic "private" {
      for_each = local.private_network_enabled ? [1] : []

      content {
        ip = local.master_private_ip_map[each.key]

        network {
          id        = local.private_network_id
          subnet_id = local.private_subnet_id
        }
      }
    }
  }

  depends_on = [
    null_resource.private_network_destroy_grace,
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

resource "null_resource" "wait_for_master_cloud_init" {
  for_each = local.masters_map

  triggers = {
    instance_id      = ovh_cloud_project_instance.masters[each.key].id
    ssh_endpoint     = local.master_public_ip_map[each.key]
    username         = var.cluster.username
    private_key_path = local_sensitive_file.ssh_private_key.filename
    timeout_seconds  = "1800"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -eu

      host='${self.triggers.ssh_endpoint}'
      user='${self.triggers.username}'
      key='${self.triggers.private_key_path}'
      deadline=$(( $(date +%s) + ${self.triggers.timeout_seconds} ))

      ssh_ready() {
        ssh \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -i "$key" \
          "$user@$host" true >/dev/null 2>&1
      }

      cloud_init_ready() {
        ssh \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -i "$key" \
          "$user@$host" 'cloud-init status --wait >/dev/null 2>&1 || sudo cloud-init status --wait >/dev/null 2>&1'
      }

      until ssh_ready; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for SSH on $host" >&2
          exit 1
        fi
        sleep 10
      done

      until cloud_init_ready; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for cloud-init on $host" >&2
          exit 1
        fi
        sleep 15
      done
    EOT
  }

  depends_on = [
    ovh_cloud_project_instance.masters,
    local_sensitive_file.ssh_private_key,
  ]
}

resource "ovh_cloud_project_instance" "workers" {
  for_each = local.workers_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"
  name           = each.value.name
  user_data      = local.worker_cloudinit[each.key]

  boot_from {
    image_id = local.master_image.id
  }

  flavor {
    flavor_id = local.worker_flavor.id
  }

  ssh_key {
    name = ovh_cloud_project_ssh_key.cluster.name
  }

  network {
    public = true

    dynamic "private" {
      for_each = local.private_network_enabled ? [1] : []

      content {
        ip = local.worker_private_ip_map[each.key]

        network {
          id        = local.private_network_id
          subnet_id = local.private_subnet_id
        }
      }
    }
  }

  depends_on = [
    null_resource.private_network_destroy_grace,
    ovh_cloud_project_network_private_subnet_v2.cluster,
  ]
}

resource "null_resource" "wait_for_worker_cloud_init" {
  for_each = local.workers_map

  triggers = {
    instance_id      = ovh_cloud_project_instance.workers[each.key].id
    ssh_endpoint     = local.worker_public_ip_map[each.key]
    username         = var.cluster.username
    private_key_path = local_sensitive_file.ssh_private_key.filename
    timeout_seconds  = "1800"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -eu

      host='${self.triggers.ssh_endpoint}'
      user='${self.triggers.username}'
      key='${self.triggers.private_key_path}'
      deadline=$(( $(date +%s) + ${self.triggers.timeout_seconds} ))

      ssh_ready() {
        ssh \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -i "$key" \
          "$user@$host" true >/dev/null 2>&1
      }

      cloud_init_ready() {
        ssh \
          -o BatchMode=yes \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 \
          -i "$key" \
          "$user@$host" 'cloud-init status --wait >/dev/null 2>&1 || sudo cloud-init status --wait >/dev/null 2>&1'
      }

      until ssh_ready; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for SSH on $host" >&2
          exit 1
        fi
        sleep 10
      done

      until cloud_init_ready; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Timed out waiting for cloud-init on $host" >&2
          exit 1
        fi
        sleep 15
      done
    EOT
  }

  depends_on = [
    ovh_cloud_project_instance.workers,
    local_sensitive_file.ssh_private_key,
  ]
}

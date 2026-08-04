resource "openstack_images_image_v2" "this" {
  name             = var.name
  image_source_url = var.image_source_url
  image_cache_path = var.image_cache_path
  decompress       = true

  container_format = "bare"
  disk_format      = "raw"
  region           = var.region

  properties = {
    os_distro = "talos"
  }
}

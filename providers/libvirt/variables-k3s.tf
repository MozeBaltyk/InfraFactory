###################################
# K3s specific variables
###################################
variable "k3s" {
  description = "K3s cluster configuration"

  type = object({
    version          = string
    token            = string
    etcd_enabled     = bool
    traefik_enabled  = bool
    servicelb_enabled = bool
    local_storage_enabled = bool
    metrics_server_enabled = bool
  })

  default = {
    version           = "v1.34.5+k3s1"
    token             = "my-super-secret-shared-token-12345"
    etcd_enabled      = true
    traefik_enabled   = true
    servicelb_enabled = true
    local_storage_enabled = true
    metrics_server_enabled = true
  }
}
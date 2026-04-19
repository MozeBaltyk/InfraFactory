###################################
# K3s specific variables
###################################
variable "k3s" {
  description = "K3s cluster configuration"

  type = object({
    version                = optional(string, "latest")
    token                  = optional(string)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    traefik_enabled        = optional(bool, true)
    servicelb_enabled      = optional(bool, true)
    local_storage_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    flannel_enabled        = optional(bool, true)
  })

  default = {}
}

###################################
# rke2 specific variables
###################################
variable "rke2" {
  description = "RKE2 cluster configuration"

  type = object({
    version                = optional(string, "latest")
    token                  = optional(string)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    ingress_nginx_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
  })

  default = {}
}

###################################
# Ansible Pull specific variables
###################################
variable "ansible" {
  type = object({
    pull = optional(object({
      repo     = string
      branch   = string
      playbook = string
      token    = optional(string)
      timer    = optional(string)
    }))
  })
  default = {}
}

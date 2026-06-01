################################
# Extra Packages installed on the nodes by cloud-init
################################
variable "extra_packages" {
  description = "Extra packages to be installed on the nodes by cloud-init"
  type        = list(string)
  default     = []
}

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
    version                = optional(string, "latest") #"v1.35.1+rke2r1"
    token                  = optional(string)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    ingress_nginx_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    kube_proxy_enabled     = optional(bool, true)
    cni                    = optional(string) # "calico", "canal", "cilium", "none" (null = RKE2 default)
    ingress_type           = optional(string) # "ingress-nginx", "traefik", "cilium", "none" (null = RKE2 default)
    cilium = optional(object({
      hubble_enabled    = optional(bool, false) # Enable Hubble observability (only with cni="cilium")
      operator_replicas = optional(number, 1)   # Cilium operator replicas when kube-proxy is disabled
    }), {})
  })

  default = {}

  validation {
    condition     = var.rke2.cni == null ? true : contains(["calico", "canal", "cilium", "none"], var.rke2.cni)
    error_message = "RKE2 cni must be one of: \"calico\", \"canal\", \"cilium\", \"none\", or null (for RKE2 default)."
  }

  validation {
    condition     = var.rke2.ingress_type == null ? true : contains(["ingress-nginx", "traefik", "cilium", "none"], var.rke2.ingress_type)
    error_message = "RKE2 ingress_type must be one of: \"ingress-nginx\", \"traefik\", \"cilium\", \"none\", or null (for RKE2 default)."
  }

  validation {
    condition     = var.rke2.ingress_type == "cilium" ? var.rke2.cni == "cilium" : true
    error_message = "RKE2 ingress_type \"cilium\" requires rke2.cni to also be \"cilium\"."
  }

  validation {
    condition     = var.rke2.cilium.operator_replicas >= 1 && floor(var.rke2.cilium.operator_replicas) == var.rke2.cilium.operator_replicas
    error_message = "RKE2 cilium.operator_replicas must be an integer greater than or equal to 1."
  }
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

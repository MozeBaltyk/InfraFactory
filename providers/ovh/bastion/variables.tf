##
## OVH credentials
##
variable "infra_provider" {
  type    = string
  default = "OVH"

  validation {
    condition     = var.infra_provider == "OVH"
    error_message = "infra_provider must be OVH."
  }
}

variable "ovh_endpoint" {
  description = "OVH API endpoint"
  type        = string
  default     = "ovh-eu"
}

variable "ovh_application_key" {
  description = "OVH application key"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
}

variable "ovh_application_secret" {
  description = "OVH application secret"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
}

variable "ovh_consumer_key" {
  description = "OVH consumer key"
  type        = string
  sensitive   = true
  nullable    = true
  default     = null
}

variable "ovh_project_service_name" {
  description = "OVHcloud Public Cloud project service name"
  type        = string
}

###################################
# Bastion identity
###################################
variable "bastion" {
  description = "Bastion identity (standalone deployment, no cluster attached at birth)"

  type = object({
    id                      = string
    domain                  = optional(string, "local")
    timezone                = optional(string, "Europe/Paris")
    region                  = string
    username                = string
    flavor_name             = optional(string, null)
    package_upgrade_enabled = optional(bool, true)
  })

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,53}[A-Za-z0-9])?$", var.bastion.id))
    error_message = "bastion.id must be a valid single DNS label of at most 55 characters."
  }

  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]{0,31}$", var.bastion.username))
    error_message = "bastion.username must be a valid Linux/SSH username (lowercase, at most 32 characters)."
  }
}

###################################
# Bootstrap access (bastion-first)
###################################
variable "admin_public_keys" {
  description = "Optional operator public SSH keys seeding the bastion authorized_keys at birth (clusters do not exist yet, so cluster keys cannot). Omit (with probe_ssh_private_key_path) to auto-generate a keypair into env/OVH/<workspace>/.key.{pub,private} via the shared ssh-keys module. Cluster pubkeys are appended afterwards by Ansible convergence."
  type        = list(string)
  default     = []
}

variable "probe_ssh_private_key_path" {
  description = "Optional local path of the private key matching one of admin_public_keys, used by the readiness probe. Omit to use the auto-generated env/OVH/<workspace>/.key.private."
  type        = string
  default     = null
}

variable "ingress_cidrs" {
  description = "Explicit operator/VPN public CIDRs allowed to reach bastion SSH (:22). The caller's current public IP is always added on top."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.ingress_cidrs :
      can(cidrnetmask(cidr)) && !strcontains(cidr, ":")
    ])
    error_message = "ingress_cidrs must contain valid IPv4 CIDR blocks."
  }
}

###################################
# Served clusters (attached iteratively)
###################################
variable "clusters" {
  description = "K8s clusters served by this bastion, attached one by one after their private network exists. bastion_ip per cluster is the shared reserved address (last usable host of the CIDR): both stacks agree with no shared state."
  type = map(object({
    cidr    = string
    vlan_id = optional(number, 0)
    masters = optional(number, 1)
    workers = optional(number, 0)

    # Optional override. Defaults to the cluster's generated public key at
    # env/<PROVIDER>/<cluster>/.key.pub (the shared ssh-keys artifact
    # convention); the map KEY must equal the cluster workspace/ENV name.
    # The cluster stack generates the key, so its keys + network targeted
    # apply runs BEFORE this stack reads it.
    public_key_file = optional(string, null)
  }))
  default = {}
}

###################################
# Ansible Pull (optional)
###################################
variable "ansible" {
  description = "Optional ansible-pull configuration for the bastion (self-healing user/playbook runs)."
  type = object({
    pull = optional(object({
      repo     = string
      branch   = string
      playbook = string
      token    = optional(string)
      timer    = optional(string)
    }))
  })
  default   = {}
  sensitive = true
}

locals {
  cluster_names_sorted = sort(keys(var.clusters))

  # Conventional per-cluster iface names (ens3 = public, then ens4+ per
  # cluster in sorted key order). These are netplan *rename targets*:
  # hot-attached NICs do not enumerate predictably, so day-2 netplan matches
  # the Neutron port MAC and renames to these names (see output.tf converge).
  cluster_ifaces = {
    for i, name in local.cluster_names_sorted :
    name => "ens${4 + i}"
  }
}

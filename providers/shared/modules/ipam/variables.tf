variable "cidr" {
  description = "Private network CIDR that nodes and the reserved bastion IP are allocated from"
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr, 0)) && !strcontains(var.cidr, ":")
    error_message = "ipam.cidr must be a valid IPv4 CIDR block (for example 10.0.0.0/24)."
  }

  validation {
    condition     = !can(cidrhost(var.cidr, 0)) || tonumber(split("/", var.cidr)[1]) <= 30
    error_message = "ipam.cidr must leave room for network, gateway, nodes, bastion and broadcast: prefix length 30 or shorter."
  }
}

variable "host_offset_base" {
  description = "First host number assigned to nodes (masters start here)"
  type        = number
  default     = 2
}

variable "masters_count" {
  description = "Number of master nodes"
  type        = number
  default     = 0
}

variable "workers_count" {
  description = "Number of worker nodes"
  type        = number
  default     = 0
}

variable "vms_count" {
  description = "Number of extra managed VMs (allocation only; existing-mode explicit IPs stay provider-side)"
  type        = number
  default     = 0
}

###
### Contract test harness (docs/architecture.md §11).
###
### Instantiates the shared modules under test. Each *.tftest.hcl sets only the
### variables its run blocks need; every other variable defaults below so a
### single harness can serve all test files.
###

terraform {
  required_version = ">= 1.6.2, < 2.0.0"

  required_providers {
    tls    = { source = "hashicorp/tls", version = "~> 4.3.0" }
    local  = { source = "hashicorp/local", version = "~> 2.9.0" }
    null   = { source = "hashicorp/null", version = "~> 3.3.0" }
    random = { source = "hashicorp/random", version = "~> 3.5" }
  }
}

### Shared variables (defaults chosen so each test file overrides only what it asserts)

variable "env_path" {
  type    = string
  default = "/tmp/opencode/contract-tests"
}

variable "cluster_id" {
  type    = string
  default = "test-cluster"
}

variable "username" {
  type    = string
  default = "ubuntu"
}

variable "cloud_init_selected" {
  type    = string
  default = "k3s"
}

variable "kube_api_endpoint" {
  type    = string
  default = "10.10.10.10"
}

variable "ssh_host" {
  type    = string
  default = "10.10.10.10"
}

variable "controller_ips" {
  type    = list(string)
  default = ["10.0.0.1", "10.0.0.2"]
}

variable "worker_ips" {
  type    = list(string)
  default = ["10.0.0.3"]
}

variable "vm_ips" {
  type    = list(string)
  default = ["10.0.0.4"]
}

variable "proxy_jump" {
  type = object({
    common_args = string
  })
  default = null
}

variable "node_generation" {
  type    = map(string)
  default = {}
}

variable "cloudinit_check_enabled" {
  type    = bool
  default = false
}

variable "k8s_flow_enabled" {
  type    = bool
  default = false
}

variable "write_local_artifacts" {
  type    = bool
  default = false
}

variable "gitops_mode" {
  type    = bool
  default = true
}

variable "node_username" {
  type    = string
  default = "ubuntu"
}

variable "timezone" {
  type    = string
  default = "Europe/Warsaw"
}

variable "extra_packages" {
  type    = list(string)
  default = []
}

variable "public_key" {
  type    = string
  default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI00000000000000000000000000000000 test@contract"
}

variable "cluster_token" {
  type      = string
  default   = "test-token-1234567890"
  sensitive = true
}

variable "package_upgrade_enabled" {
  type    = bool
  default = false
}

variable "k3s" {
  type = object({
    version                = optional(string, "latest")
    data_dir               = optional(string, null)
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

variable "rke2" {
  type = object({
    version                = optional(string, "latest")
    data_dir               = optional(string, null)
    tls_sans               = optional(list(string), [])
    etcd_enabled           = optional(bool, true)
    ingress_nginx_enabled  = optional(bool, true)
    metrics_server_enabled = optional(bool, true)
    cni                    = optional(string, null)
    ingress_type           = optional(string, null)
    kube_proxy_enabled     = optional(bool, null)
    cilium = optional(object({
      hubble_enabled    = optional(bool, false)
      operator_replicas = optional(number, 1)
      l2announcements = optional(object({
        enabled           = optional(bool, false)
        lb_pool_start     = optional(string, null)
        lb_pool_end       = optional(string, null)
        network_interface = optional(string, null)
      }), {})
    }), {})
  })
  default = {}
}

variable "ansible" {
  type = object({
    pull = optional(object({
      repo     = optional(string, null)
      branch   = optional(string, null)
      playbook = optional(string, null)
      token    = optional(string, null)
      timer    = optional(string, null)
    }), null)
  })
  default = {}
}

variable "vms" {
  type = map(object({
    hostname           = string
    fqdn               = string
    domain             = string
    node_role          = string
    is_first_master    = bool
    first_master_ip    = optional(string, null)
    current_private_ip = optional(string, null)
    extra_disks = list(object({
      wwn        = string
      mount_path = string
      filesystem = string
    }))
    k3s_tls_sans        = list(string)
    rke2_tls_sans       = list(string)
    cloud_init_selected = optional(string, null)
  }))
  default = {}
}

variable "k3s_token" {
  type      = string
  default   = ""
  sensitive = true
}

variable "rke2_token" {
  type      = string
  default   = ""
  sensitive = true
}

### Modules under test

module "ssh_keys" {
  source = "../../providers/shared/modules/ssh-keys"

  env_path              = var.env_path
  write_local_artifacts = var.write_local_artifacts
  gitops_mode           = var.gitops_mode
  cloud_init_selected   = var.cloud_init_selected
  k3s_token             = var.k3s_token
  rke2_token            = var.rke2_token
}

module "ansible_artifacts" {
  source = "../../providers/shared/modules/ansible-artifacts"

  env_path                = var.env_path
  cluster_id              = var.cluster_id
  username                = var.username
  cloud_init_selected     = var.cloud_init_selected
  kube_api_endpoint       = var.kube_api_endpoint
  ssh_host                = var.ssh_host
  controller_ips          = var.controller_ips
  worker_ips              = var.worker_ips
  vm_ips                  = var.vm_ips
  proxy_jump              = var.proxy_jump
  node_generation         = var.node_generation
  cloudinit_check_enabled = var.cloudinit_check_enabled
  k8s_flow_enabled        = var.k8s_flow_enabled
  write_local_artifacts   = var.write_local_artifacts
  gitops_mode             = var.gitops_mode
}

module "cloudinit_renderer" {
  source = "../../providers/shared/modules/cloudinit-renderer"

  cloud_init_selected     = var.cloud_init_selected
  node_username           = var.node_username
  timezone                = var.timezone
  extra_packages          = var.extra_packages
  public_key              = var.public_key
  cluster_token           = var.cluster_token
  package_upgrade_enabled = var.package_upgrade_enabled
  k3s                     = var.k3s
  rke2                    = var.rke2
  ansible                 = var.ansible
  vms                     = var.vms
}

### Re-expose outputs for assertions

output "ssh_private_key_pem" {
  value     = module.ssh_keys.private_key_pem
  sensitive = true
}

output "ssh_public_key_openssh" {
  value     = module.ssh_keys.public_key_openssh
  sensitive = true
}

output "ssh_cluster_token" {
  value     = module.ssh_keys.cluster_token
  sensitive = true
}

output "gitops_hosts_ini" {
  value = module.ansible_artifacts.gitops_hosts_ini
}

output "gitops_ansible_cfg" {
  value = module.ansible_artifacts.gitops_ansible_cfg
}

output "rendered_cloudinit" {
  value     = module.cloudinit_renderer.rendered
  sensitive = true
}

### standard_d8s_v5 = 8vcpu/32G
variable "instance_size" {
  type = string
  description = "Instance type used for all linux virtual machines"
  default = "standard_d8s_v5" 
}

variable "controller_count" {
  type    = number
  description = "number of controllers"
  default = "1"
}

variable "worker_count" {
  type    = number
  description = "number of workers"
  default = "2"
}

variable "domain" {
  description = "Domain given to loadbalancer and VMs"
  default = "example.com"
}

variable "region" {
  description = "Unique bucket name for storing terraform backend data"
  default = "westeurope"
}

variable "GITREPO_UN_ID" {
  type    = string
  description = "git repository run id"
  default = "quickstart"
}

variable "terraform_backend_bucket_name" {
  description = "Unique bucket name for storing terraform backend data"
  default = "terraform-backend-factory-quickstart"
}

variable "mount_point" {
  description = "Unique bucket name for storing terraform backend data"
  default = "/opt/factory"
}

##
## Azure credentials
##

variable "azure_subscription_id" {
  description = "Azure Subscription ID"
}

variable "azure_client_id" {
  description = "Azure Client ID"
}

variable "azure_client_secret" {
  description = "Azure Client Secret"
}

variable "azure_tenant_id" {
  description = "Azure tenant ID"
}

variable "prefix" {
  type        = string
  description = "Prefix added to names of all resources"
  default     = "slaz"
}

variable "node_username" {
  type    = string
  description = "user created on VM"
  default = "factory"
}

variable "az_system" {
  type    = string
  description = "os used for VM"
  default = "9-lvm-gen2"
}

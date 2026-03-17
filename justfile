#!/usr/bin/env just --justfile
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

##############################################
# Global configuration
##############################################

PROVIDER  := env_var_or_default("PROVIDER", "KVM")
ENV       := env_var_or_default("ENV", "lab")

# Justfile internal vars
TF_AZ  := "./providers/azure"
TF_KVM := "./providers/libvirt"
TF_OVH := "./providers/ovh"
TF_DO  := "./providers/digitalocean"
ENV_TFVARS_PATH := "../../env/" + PROVIDER + "/" + ENV + ".tfvars"

# Default recipe: print help
_help:
  @just --list --unsorted 

# Print current configuration
env:
	@echo "Provider and config applied:"
	@echo "  PROVIDER  = {{PROVIDER}}"
	@echo "  ENV       = {{ENV}}"
	@echo "   |-> ENV_TFVARS_PATH = {{ENV_TFVARS_PATH}}"

##############################################
# Entry points
##############################################

# Validate Opentofu scripts
validate:
	just _validate-{{PROVIDER}}

# Plan on Provider specified in PROVIDER env variable (default: KVM)
plan:
	just _plan-{{PROVIDER}}

# Deploy on Provider specified in PROVIDER env variable (default: KVM)
deploy:
	just _deploy-{{PROVIDER}}

# Destroy on Provider specified in PROVIDER env variable (default: KVM)
destroy:
	just _destroy-{{PROVIDER}}

#---------------------------------------------
# Azure recipes
#---------------------------------------------
_validate-AZ:
	@cd {{TF_AZ}} && tofu init -backend=false && tofu validate

_workspace-AZ:
	@cd {{TF_AZ}} && tofu workspace select {{ENV}} || tofu workspace new {{ENV}}

_plan-AZ:
	@cd {{TF_AZ}} && tofu init
	@cd {{TF_AZ}} && just _workspace-AZ
	@cd {{TF_AZ}} && tofu plan -var-file={{ENV_TFVARS_PATH}}

_deploy-AZ:
	@cd {{TF_AZ}} && tofu init
	@cd {{TF_AZ}} && just _workspace-AZ
	@cd {{TF_AZ}} && tofu apply -auto-approve -var-file={{ENV_TFVARS_PATH}}

_destroy-AZ:
	@cd {{TF_AZ}} && tofu init
	@cd {{TF_AZ}} && just _workspace-AZ
	@cd {{TF_AZ}} && tofu destroy -auto-approve -var-file={{ENV_TFVARS_PATH}}

#---------------------------------------------
# KVM Recipes
#---------------------------------------------
_validate-KVM:
	@cd {{TF_KVM}} && tofu init -backend=false && tofu validate

_workspace-KVM:
	@cd {{TF_KVM}} && tofu workspace select {{ENV}} || tofu workspace new {{ENV}}

_plan-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && just _workspace-KVM
	@cd {{TF_KVM}} && tofu plan -var-file={{ENV_TFVARS_PATH}}

_deploy-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && just _workspace-KVM
	@cd {{TF_KVM}} && tofu apply -auto-approve -var-file={{ENV_TFVARS_PATH}}

_destroy-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && just _workspace-KVM
	@cd {{TF_KVM}} && tofu destroy -auto-approve -var-file={{ENV_TFVARS_PATH}}

#---------------------------------------------
# Ansible recipes
#---------------------------------------------
# Check ansible connectivity for specified environment
ping:
	@ANSIBLE_CONFIG=./env/{{PROVIDER}}/{{ENV}}/ansible.cfg ansible all -i ./env/{{PROVIDER}}/{{ENV}}/hosts.ini -m ping

# Run ansible playbook for specified environment
play playbook *ARGS:
	@ANSIBLE_CONFIG=./env/{{PROVIDER}}/{{ENV}}/ansible.cfg ansible-playbook -i ./env/{{ENV}}/hosts.ini {{playbook}} {{ARGS}}
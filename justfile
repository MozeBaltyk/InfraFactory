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

AZ_REQUIRED := "AZ_SUBS_ID AZ_CLIENT_ID AZ_CLIENT_SECRET AZ_TENANT_ID"
AZ_SIZE_MATTERS := env_var_or_default("AZ_SIZE_MATTERS", "")

# Default recipe: print help
_help:
  @just --list --unsorted 

# Print current configuration
env:
	@echo "Provider and config applied:"
	@echo "  PROVIDER            = {{PROVIDER}}"
	@echo "  ENV_TFVARS_PATH     = {{ENV_TFVARS_PATH}}"

##############################################
# Helper recipes
##############################################

_validate-az-env:
	@for v in {{AZ_REQUIRED}}; do \
	  : "${!v:?Environment variable $v must be set}"; \
	done

_retry cmd:
	@for i in {1..2}; do \
	  echo "Attempt $i..."; \
	  {{cmd}} && break || sleep 2; \
	done

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

##############################################
# Azure recipes
##############################################
_validate-AZ: _validate-az-env
	@cd {{TF_AZ}} && tofu init -backend=false && tofu validate

_plan-AZ: _validate-az-env
	@cd {{TF_AZ}} && tofu init
	@cd {{TF_AZ}} && tofu plan \
	  -var azure_subscription_id=$AZ_SUBS_ID \
	  -var azure_client_id=$AZ_CLIENT_ID \
	  -var azure_client_secret=$AZ_CLIENT_SECRET \
	  -var azure_tenant_id=$AZ_TENANT_ID \
	  -var instance_size={{AZ_SIZE_MATTERS}}

_deploy-AZ: _validate-az-env
	@just _retry "cd {{TF_AZ}} && tofu init && tofu apply -auto-approve \
	  -var azure_subscription_id=$AZ_SUBS_ID \
	  -var azure_client_id=$AZ_CLIENT_ID \
	  -var azure_client_secret=$AZ_CLIENT_SECRET \
	  -var azure_tenant_id=$AZ_TENANT_ID \
	  -var instance_size={{AZ_SIZE_MATTERS}}"

_destroy-AZ: _validate-az-env
	@cd {{TF_AZ}} && tofu destroy -auto-approve \
	  -var azure_subscription_id=$AZ_SUBS_ID \
	  -var azure_client_id=$AZ_CLIENT_ID \
	  -var azure_client_secret=$AZ_CLIENT_SECRET \
	  -var azure_tenant_id=$AZ_TENANT_ID \
	  -var instance_size={{AZ_SIZE_MATTERS}}

#---------------------------------------------
# KVM Recipes
#---------------------------------------------
_validate-KVM:
	@cd {{TF_KVM}} && tofu init -backend=false && tofu validate

_plan-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && tofu plan -var-file={{ENV_TFVARS_PATH}}

_deploy-KVM:
	@cd {{TF_KVM}} && tofu apply -auto-approve -var-file={{ENV_TFVARS_PATH}}

_destroy-KVM:
	@cd {{TF_KVM}} && tofu destroy -auto-approve -var-file={{ENV_TFVARS_PATH}}
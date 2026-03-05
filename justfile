#!/usr/bin/env just --justfile
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

##############################################
# Global configuration
##############################################
PROVIDER := env_var_or_default("PROVIDER", "KVM")
WORKERS := env_var_or_default("WORKERS", "0")
MASTERS := env_var_or_default("MASTERS", "1")

CPU_SIZE_MATTERS := env_var_or_default("CPU_SIZE_MATTERS", "2")
MEM_SIZE_MATTERS := env_var_or_default("MEM_SIZE_MATTERS", "4096")
SELECTED_VERSION := env_var_or_default("SELECTED_VERSION", "ubuntu24")

AZ_SIZE_MATTERS := env_var_or_default("AZ_SIZE_MATTERS", "standard_d8s_v5")
AZ_REQUIRED := "AZ_SUBS_ID AZ_CLIENT_ID AZ_CLIENT_SECRET AZ_TENANT_ID"

TF_AZ  := "./providers/azure"
TF_KVM := "./providers/libvirt"
TF_OVH := "./providers/ovh"
TF_DO  := "./providers/digitalocean"

# Default recipe: print help
_help:
  @just --list --unsorted 

# Print current configuration
env:
	@echo "Provider: {{PROVIDER}}"
	@echo "Workers: {{WORKERS}}"
	@echo "Masters: {{MASTERS}}"
	@echo "CPU Size: {{CPU_SIZE_MATTERS}}"
	@echo "Memory Size: {{MEM_SIZE_MATTERS}}"

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

# Plan on Provider specified in PROVIDER env variable (default: KVM)
plan:
	just _plan-{{PROVIDER}}

# Deploy on Provider specified in PROVIDER env variable (default: KVM)
deploy:
	just _deploy-{{PROVIDER}}

# Destroy on PProvider specified in PROVIDER env variable (default: KVM)
destroy:
	just _destroy-{{PROVIDER}}

##############################################
# Azure recipes
##############################################
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
	@cd {{TF_AZ}} && tofu init
	@cd {{TF_AZ}} && tofu destroy -auto-approve \
	  -var azure_subscription_id=$AZ_SUBS_ID \
	  -var azure_client_id=$AZ_CLIENT_ID \
	  -var azure_client_secret=$AZ_CLIENT_SECRET \
	  -var azure_tenant_id=$AZ_TENANT_ID \
	  -var instance_size={{AZ_SIZE_MATTERS}}

##############################################
# KVM recipes
##############################################

_plan-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && tofu plan \
	  -var workers_number={{WORKERS}} \
	  -var masters_number={{MASTERS}} \
	  -var cpu_size={{CPU_SIZE_MATTERS}} \
	  -var memory_size={{MEM_SIZE_MATTERS}} \
	  -var selected_version={{SELECTED_VERSION}}

_deploy-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && tofu apply -auto-approve \
	  -var workers_number={{WORKERS}} \
	  -var masters_number={{MASTERS}} \
	  -var cpu_size={{CPU_SIZE_MATTERS}} \
	  -var memory_size={{MEM_SIZE_MATTERS}} \
	  -var selected_version={{SELECTED_VERSION}}

_destroy-KVM:
	@cd {{TF_KVM}} && tofu init
	@cd {{TF_KVM}} && tofu destroy -auto-approve \
	  -var workers_number={{WORKERS}} \
	  -var masters_number={{MASTERS}} \
	  -var cpu_size={{CPU_SIZE_MATTERS}} \
	  -var memory_size={{MEM_SIZE_MATTERS}} \
	  -var selected_version={{SELECTED_VERSION}}

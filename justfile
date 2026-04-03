#!/usr/bin/env just --justfile

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

mod azure "providers/azure/justfile"
mod libvirt "providers/libvirt/justfile"
mod ovh "providers/ovh/justfile"

PROVIDER := env_var_or_default("PROVIDER", "KVM")
ENV := env_var_or_default("ENV", "lab")

_help:
    @just --list --unsorted

[private]
_provider-module:
    @case "{{ PROVIDER }}" in AZ) echo azure ;; KVM) echo libvirt ;; OVH) echo ovh ;; *) echo "Unsupported PROVIDER={{ PROVIDER }}. Use KVM, AZ, or OVH." >&2; exit 1 ;; esac

[private]
_provider-tfvars:
    @case "{{ PROVIDER }}" in AZ) echo ./env/AZ/{{ ENV }}.tfvars ;; KVM) echo ./env/KVM/{{ ENV }}.tfvars ;; OVH) echo ./env/OVH/{{ ENV }}.tfvars ;; *) echo "Unsupported PROVIDER={{ PROVIDER }}. Use KVM, AZ, or OVH." >&2; exit 1 ;; esac

# Print current configuration
env:
    @echo "Provider and config applied:"
    @echo "  PROVIDER  = {{ PROVIDER }}"
    @echo "  ENV       = {{ ENV }}"
    @echo "   |-> MODULE          = $(just _provider-module)"
    @echo "   |-> ENV_TFVARS_PATH = $(just _provider-tfvars)"

# Validate Opentofu scripts
validate:
    @just $(just _provider-module)::validate

# Plan on Provider specified in PROVIDER env variable (default: KVM)
plan:
    @just $(just _provider-module)::plan

# Deploy on Provider specified in PROVIDER env variable (default: KVM)
deploy:
    @just $(just _provider-module)::deploy

# Destroy on Provider specified in PROVIDER env variable (default: KVM)
destroy:
    @just $(just _provider-module)::destroy

# Check ansible connectivity for specified environment
ping:
    @ANSIBLE_CONFIG=./env/{{ PROVIDER }}/{{ ENV }}/ansible.cfg ansible K8S_CLUSTER -i ./env/{{ PROVIDER }}/{{ ENV }}/hosts.ini -m ping

# Run ansible playbook for specified environment
play playbook *ARGS:
    @ANSIBLE_CONFIG=./env/{{ PROVIDER }}/{{ ENV }}/ansible.cfg ansible-playbook -i ./env/{{ PROVIDER }}/{{ ENV }}/hosts.ini {{ playbook }} {{ ARGS }}

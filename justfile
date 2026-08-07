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
    @module="$(just _provider-module)"; \
      tfvars="$(just _provider-tfvars)"; \
      provider_path="providers/$module"; \
      env_dir="./env/{{ PROVIDER }}/{{ ENV }}"; \
      cloud_init_selected=''; \
      if test -f "$tfvars"; then \
        while IFS= read -r line; do \
          case "$line" in \
            *cloud_init_selected*'='*\"*) cloud_init_selected="${line#*\"}"; cloud_init_selected="${cloud_init_selected%%\"*}"; break ;; \
          esac; \
        done < "$tfvars"; \
      fi; \
      if test -t 1 && test -z "${NO_COLOR:-}"; then \
        reset=$'\033[0m'; bold=$'\033[1m'; blue=$'\033[34m'; green=$'\033[32m'; red=$'\033[31m'; yellow=$'\033[33m'; dim=$'\033[2m'; \
      else \
        reset=''; bold=''; blue=''; green=''; red=''; yellow=''; dim=''; \
      fi; \
      status_path() { \
        label="$1"; \
        path="$2"; \
        if test -e "$path"; then \
          printf '  %-16s %s[ok]%s      %s\n' "$label" "$green" "$reset" "$path"; \
        else \
          printf '  %-16s %s[missing]%s %s\n' "$label" "$yellow" "$reset" "$path"; \
        fi; \
      }; \
      status_na() { \
        label="$1"; \
        why="$2"; \
        printf '  %-16s %s[n/a]%s     %s\n' "$label" "$dim" "$reset" "$why"; \
      }; \
      printf '%s%s%s\n' "$bold" 'InfraFactory environment' "$reset"; \
      printf '%s%s%s\n' "$dim" '------------------------' "$reset"; \
      printf '\n%s%s%s\n' "$blue" 'Provider' "$reset"; \
      printf '  %-16s %s\n' 'PROVIDER' '{{ PROVIDER }}'; \
      printf '  %-16s %s\n' 'Module' "$module"; \
      printf '  %-16s %s\n' 'Provider path' "$provider_path"; \
      printf '\n%s%s%s\n' "$blue" 'Environment' "$reset"; \
      printf '  %-16s %s\n' 'ENV' '{{ ENV }}'; \
      status_path 'Tfvars' "$tfvars"; \
      printf '  %-16s %s\n' 'Workspace' '{{ ENV }}'; \
      printf '\n%s%s%s\n' "$blue" 'Generated files' "$reset"; \
      status_path 'Env dir' "$env_dir"; \
      if test "$cloud_init_selected" = 'talos'; then \
        status_path 'Talosconfig' "$env_dir/talosconfig"; \
        status_path 'Kubeconfig' "$env_dir/kubeconfig"; \
        status_na 'Inventory' 'Talos mode (Ansible skipped)'; \
        status_na 'Ansible cfg' 'Talos mode (Ansible skipped)'; \
        status_na 'SSH key' "$env_dir/.key.private"; \
      else \
        status_path 'Inventory' "$env_dir/hosts.ini"; \
        status_path 'Ansible cfg' "$env_dir/ansible.cfg"; \
        status_path 'Kubeconfig' "$env_dir/kubeconfig"; \
        status_path 'SSH key' "$env_dir/.key.private"; \
      fi; \
      printf '\n%s%s%s\n' "$blue" 'Useful commands' "$reset"; \
      printf '  %-16s %s\n' 'Validate' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just validate'; \
      printf '  %-16s %s\n' 'Plan' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just plan'; \
      printf '  %-16s %s\n' 'Plan VM' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just plan NAME'; \
      printf '  %-16s %s\n' 'Deploy' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just deploy'; \
      printf '  %-16s %s\n' 'Deploy VM' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just deploy NAME'; \
      printf '  %-16s %s\n' 'Replace VM' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just replace NAME'; \
      printf '  %-16s %s\n' 'Destroy' 'PROVIDER={{ PROVIDER }} ENV={{ ENV }} just destroy'; \
      if ! test -f "$tfvars"; then \
        printf '\n%s%s%s\n' "$yellow" 'Hint' "$reset"; \
        printf '  %s\n' "Create $tfvars from ./env/{{ PROVIDER }}/tfvars.example before plan/deploy."; \
      fi

# Validate Opentofu scripts
validate:
    @just $(just _provider-module)::validate

# Plan on Provider specified in PROVIDER env variable (default: KVM). Pass NAME to target one VM.
plan NAME='':
    @ENV={{ ENV }} just $(just _provider-module)::plan {{ NAME }}

# Deploy on Provider specified in PROVIDER env variable (default: KVM). Pass NAME to target one VM.
deploy NAME='':
    @ENV={{ ENV }} just $(just _provider-module)::deploy {{ NAME }}

# Force rebuild one VM on the selected provider
replace NAME:
    @ENV={{ ENV }} just $(just _provider-module)::replace {{ NAME }}

# Destroy on Provider specified in PROVIDER env variable (default: KVM). Pass STALE=true to skip refresh (dead/broken machines)
destroy STALE='':
    @just $(just _provider-module)::destroy {{ STALE }}

# Check Kubernetes cluster on Provider specified in PROVIDER env variable (default: KVM)
check:
    @KUBECONFIG=./env/{{ PROVIDER }}/{{ ENV }}/kubeconfig kubectl get nodes -o wide

# Check ansible connectivity for specified environment
ping:
    @ANSIBLE_CONFIG=./env/{{ PROVIDER }}/{{ ENV }}/ansible.cfg ansible K8S_CLUSTER -i ./env/{{ PROVIDER }}/{{ ENV }}/hosts.ini -m ping

# Run ansible playbook for specified environment (ex: just play providers/shared/ansible/check_cloudinit.yml)
play playbook *ARGS:
    @ANSIBLE_CONFIG=./env/{{ PROVIDER }}/{{ ENV }}/ansible.cfg ansible-playbook -i ./env/{{ PROVIDER }}/{{ ENV }}/hosts.ini {{ playbook }} {{ ARGS }}

#!/usr/bin/env just --justfile

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

mod azure "providers/azure/justfile"
mod libvirt "providers/libvirt/justfile"
mod ovh "providers/ovh/justfile"

PROVIDER_RAW := env_var_or_default("PROVIDER", "KVM")
PROVIDER := if PROVIDER_RAW =~ '^(AZ|KVM|OVH)$' { PROVIDER_RAW } else { error("PROVIDER must be AZ, KVM, or OVH") }
ENV_RAW := env_var_or_default("ENV", "lab")
ENV := if ENV_RAW =~ '^[A-Za-z0-9._-]+$' { ENV_RAW } else { error("ENV must be a nonempty identifier containing only A-Za-z0-9._-") }

_help:
    @just --list --unsorted

[private]
_provider-module:
    @case {{ quote(PROVIDER) }} in AZ) echo azure ;; KVM) echo libvirt ;; OVH) echo ovh ;; esac

# Print current configuration
env:
    @bash scripts/env-status.sh {{ quote(PROVIDER) }} {{ quote(ENV) }}

# Validate Opentofu scripts
validate:
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::validate"

# Run shared-module contract tests (tests/contracts)
test:
    @tofu -chdir=tests/contracts test

# Plan on Provider specified in PROVIDER env variable (default: KVM). Pass NAME to target one VM.
plan NAME='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::plan" {{ quote(NAME) }}

# Deploy on Provider specified in PROVIDER env variable (default: KVM). Pass NAME to target one VM.
deploy NAME='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::deploy" {{ quote(NAME) }}

# Force rebuild one VM through the selected provider's replacement graph
replace NAME:
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::replace" {{ quote(NAME) }}

# Destroy on Provider specified in PROVIDER env variable (default: KVM). Pass STALE=true to skip refresh (dead/broken machines)
destroy STALE='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::destroy" {{ quote(STALE) }}

# Check Kubernetes cluster on Provider specified in PROVIDER env variable (default: KVM)
check:
    @KUBECONFIG={{ quote("./env/" + PROVIDER + "/" + ENV + "/kubeconfig") }} kubectl get nodes -o wide

# Check ansible connectivity for specified environment
ping:
    @ANSIBLE_CONFIG={{ quote("./env/" + PROVIDER + "/" + ENV + "/ansible.cfg") }} ansible K8S_CLUSTER -i {{ quote("./env/" + PROVIDER + "/" + ENV + "/hosts.ini") }} -m ping

# Run ansible playbook for specified environment (ex: just play providers/shared/ansible/check_cloudinit.yml)
[script("bash"), positional-arguments]
play playbook *ARGS:
    export ANSIBLE_CONFIG={{ quote("./env/" + PROVIDER + "/" + ENV + "/ansible.cfg") }}
    playbook=$1
    shift
    exec ansible-playbook -i {{ quote("./env/" + PROVIDER + "/" + ENV + "/hosts.ini") }} "$playbook" "$@"

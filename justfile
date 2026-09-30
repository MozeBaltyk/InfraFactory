#!/usr/bin/env just --justfile

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

mod azure "providers/azure/justfile"
mod libvirt "providers/libvirt/justfile"
mod ovh "providers/ovh/justfile"

PROVIDER_RAW := env_var_or_default("PROVIDER", "KVM")
PROVIDER := if PROVIDER_RAW =~ '^(AZ|KVM|OVH)$' { PROVIDER_RAW } else { error("PROVIDER must be AZ, KVM, or OVH") }
ENV_RAW := env_var_or_default("ENV", "lab")
ENV := if ENV_RAW == "." { error("ENV must not be . or ..") } else if ENV_RAW == ".." { error("ENV must not be . or ..") } else if ENV_RAW =~ '^[A-Za-z0-9._-]+$' { ENV_RAW } else { error("ENV must be a nonempty path-safe identifier containing only A-Za-z0-9._-") }
PROJECT_RAW := env_var_or_default("PROJECT", "")
PROJECT := if PROVIDER != "OVH" { PROJECT_RAW } else if PROJECT_RAW == "." { error("PROJECT must not be . or ..") } else if PROJECT_RAW == ".." { error("PROJECT must not be . or ..") } else if PROJECT_RAW =~ '^[A-Za-z0-9._-]+$' { PROJECT_RAW } else { error("PROJECT is required for OVH and must be a path-safe identifier containing only A-Za-z0-9._-") }
ENV_PATH := if PROVIDER == "OVH" { "./env/OVH/" + PROJECT + "/clusters/" + ENV } else { "./env/" + PROVIDER + "/" + ENV }

_help:
    @just --list --unsorted

[private]
_provider-module:
    @case {{ quote(PROVIDER) }} in AZ) echo azure ;; KVM) echo libvirt ;; OVH) echo ovh ;; esac

# ── Context — scripts/context/ ───────────────────────────

# Show configuration, artifacts, auth/backend checks, and OVH cross-stack status
[group('Context')]
env:
    @bash scripts/env-status.sh {{ quote(PROVIDER) }} {{ quote(ENV) }}

# Inventory provisioned resources and access details from OpenTofu state
[group('Context')]
report:
    @bash scripts/report.sh {{ quote(PROVIDER) }} {{ quote(ENV) }}

# Best-effort sync allowlisted non-secret OVH artifacts to the bastion
[group('Context')]
sync-info:
    @bash scripts/sync-guests-info.sh

# ── Opentofu ───────────────────────────

# Validate Opentofu scripts
[group('Opentofu')]
validate:
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::validate"

# Plan Cluster. (Pass NAME to target one VM.)
[group('Opentofu')]
plan NAME='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::plan" {{ quote(NAME) }}

# Deploy infrastructure; on OVH, no NAME runs the complete workflow and NAME is cluster-only.
[group('Opentofu')]
deploy NAME='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::deploy" {{ quote(NAME) }}

# Force rebuild one VM.
[group('Opentofu')]
replace NAME:
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::replace" {{ quote(NAME) }}

# Destroy Cluster. Pass STALE=true to skip refresh (dead/broken machines)
[group('Opentofu')]
destroy STALE='':
    @ENV={{ quote(ENV) }} just "$(just _provider-module)::destroy" {{ quote(STALE) }}

# ── Post-Checks ───────────────────────────

# Check Kubernetes cluster if reachable
[group('Post-Checks')]
check:
    @KUBECONFIG={{ quote(ENV_PATH + "/kubeconfig") }} kubectl get nodes -o wide

# Check ansible connectivity
[group('Post-Checks')]
ping:
    @ANSIBLE_CONFIG={{ quote(ENV_PATH + "/ansible.cfg") }} ansible K8S_CLUSTER -i {{ quote(ENV_PATH + "/hosts.ini") }} -m ping

# ── Provisioning ───────────────────────────

# Run ansible playbook for specified environment (ex: just play providers/shared/ansible/check_cloudinit.yml)
[group('Provisioning')]
[positional-arguments]
[script("bash")]
play playbook *ARGS:
    export ANSIBLE_CONFIG={{ quote(ENV_PATH + "/ansible.cfg") }}
    playbook=$1
    shift
    exec ansible-playbook -i {{ quote(ENV_PATH + "/hosts.ini") }} "$playbook" "$@"

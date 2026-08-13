<p align="center">
  <img src="assets/InfraFactory.png" alt="Project Logo" width="180">
</p>

<p align="center">
  A provider-agnostic, modular infrastructure factory for deploying multi-cloud clusters with OpenTofu and Ansible.
</p>

---

## Overview

**InfraFactory** is a **reproducible infrastructure framework** designed to provision virtual machines and Kubernetes clusters across multiple environments — locally (KVM/libvirt) or on cloud providers — using a consistent and declarative approach.

It enables you to deploy VM-only environments, Kubernetes clusters with varying numbers of control plane (masters) and worker nodes, and optional standalone VMs, while supporting multiple Kubernetes distributions.

✨ **Key Features**
- ☁️ **Multi-platform**:    
        - Libvirt (local and distant KVM)    
        - Azure    
        - OVH    
- 🌍 **Multi-environment**: One codebase, multiple environments via simple `tfvars` files
- 🔄 **Declarative Infrastructure**: Define your entire cluster in a single configuration
- ⚙️ **Cloud-init** Bootstrap:   
        - Bare virtual machines    
        - Kubernetes via K3s or RKE2    
- 🚀 **Post-Configuration**: Extend and customize nodes using optional ansible-pull for continuous configuration management

**Core Workflow:**
```
OpenTofu (provision VMs)
  → cloud-init templates (default/k3s/rke2, when user data is enabled)
    → inventory generation
      → Kubernetes-only Ansible post-steps and optional ansible-pull
```

---

## Prerequisites

- **OpenTofu** (>= 1.6.2)
  - Install with `arkade get tofu` pinned to version 1.6.2
  - For Debian/Ubuntu:
      `curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh`
      `chmod +x install-opentofu.sh && ./install-opentofu.sh --install-method deb`

- **Just** (>= 1.0.0)
  - Install with `arkade get just`
  - Or: `apt install just` (Debian/Ubuntu)

- **Provider-specific requirements:**
  - **Libvirt**: KVM/QEMU installed and running (`libvirt-daemon`, `libvirt-dev`, `mkisofs`)
      - `sudo usermod -aG libvirt $(whoami)`
      - `sudo usermod -aG kvm $(whoami)`
  - **OVH**: OVH API credentials configured
  - **Azure**: Azure CLI and subscription credentials

- **Nice to have**:
  - install and set in your path `arkade`
  - `arkade get kubecm`
  - `arkade get kubectl`
  - `arkade get k9s`
  - `cockpit` to manage in a web interface the libvirt VMs
  - `ansible`

---

## Quick Start

### 1. Configure Environment

Copy an example configuration and customize it:

```bash
# For Libvirt (local KVM)
cp env/KVM/tfvars.example env/KVM/lab.tfvars
# Edit as needed
vim env/KVM/lab.tfvars

# For Azure
cp env/AZ/tfvars.example env/AZ/lab.tfvars

# For OVH
cp env/OVH/tfvars.example env/OVH/lab.tfvars
```

### 2. Validate and Plan

```bash
# Target which env and which provider
export PROVIDER=AZ
export ENV=lab
just env

# Validate
just validate

# Plan 
just plan
```

### 3. Use it

```bash
# Deploy infrastructure
just deploy

# Ping
just ping

# Destroy 
just destroy
```

### 4. Access Your Deployment

After deployment completes, VMs are reachable through the generated SSH key and inventory. For `k3s` or `rke2` deployments with master user data enabled, the cluster is already running via cloud-init:

```bash
ssh -o StrictHostKeyChecking=no -i ./env/<PROVIDER>/<env>/.key.private localadmin@<ip>
```

The Ansible inventory is generated in `env/<PROVIDER>/<env>/hosts.ini` for additional configuration tasks. Standalone `infra.vms` are listed in the shared `[VMS]` inventory group.

---

## Complete Usage Guide

### Available Commands

Run `just` to see all available recipes:

```bash
just
```

Available commands:

| Command | Description |
|---------|-------------|
| `just env` | Print current provider and configuration |
| `just validate` | Validate Terraform/OpenTofu scripts |
| `just plan` | Plan infrastructure changes |
| `just deploy` | Apply and create infrastructure |
| `just destroy` | Tear down infrastructure |
| `just ping` | Ping VMs with ansible |
| `just check` | Check k8s access |
| `just play` | Run an Ansible playbook against the cluster |
| `just replace NAME` | Replace a named VM; OVH applies the full dependency graph, while AZ/KVM remain target-scoped |



### Configuration Files

Each environment is defined by a `.tfvars` file in `env/<PROVIDER>/`:

**Example: `env/KVM/lab.tfvars`**
```hcl
cluster = {
  id                  = "factory"
  domain              = "lab"
  timezone            = "Europe/Paris"
  node_name_format    = "serial"
  cloud_init_selected = "k3s"
  username            = "localadmin"
  factory_root_path   = "/srv"
}

infra = {
  masters = {
    count     = 1
    cpu       = 2
    disk_size = 10
    memory_gb = 4
  }
  workers = {
    count     = 2
    cpu       = 2
    disk_size = 10
    memory_gb = 4
  }
  vms = {
    count     = 0
    cpu       = 2
    disk_size = 10
    memory_gb = 4
  }
}

network = {
  mode    = "nat"
  ip_type = "dhcp"
}

libvirt = {
  remote = false
  user   = "root"
  host   = "localhost"
  system = "system"
}
```

### Libvirt node naming

The libvirt provider accepts `cluster.node_name_format`:

- `serial` (default): names every node from one shared sequence, for example `factory-node01`, `factory-node02`, `factory-node03`
- `role`: names masters and workers independently, for example `factory-m01`, `factory-m02`, `factory-w01`

`serial` keeps workers continuing after masters, while `role` keeps per-role numbering stable as long as each role count stays unchanged.

Important lifecycle caveats:

- Changing `cluster.node_name_format` after resources already exist is a migration and will usually require state moves and possibly recreation.
- In `serial` mode, changing `infra.masters.count` renumbers workers because workers continue after masters.
- In `serial` mode, that renumbering can also reuse the same node identity across roles. For example, `node02` can be a worker in one topology and become a master after increasing `infra.masters.count`.
- Because libvirt resources use these names as resource keys and object names, `serial` mode is best treated as stable only when the master count is fixed for that environment.
- If you need safer per-role scaling over time, prefer `role` mode.

## Project Structure

```txt
InfraFactory/
├── AGENTS.md                     # AI assistant context
├── README.md                     # The only doc, I will produce in my life.
├── TODO.md                       # Task tracking
├── justfile                      # CLI orchestrator (run: just)
├── gitops/                       # Optional Flux/tofu-controller management layer
│   ├── apps/                     # Flux-managed platform apps and controllers
│   ├── flux/                     # Flux system config and Terraform CR overlays
│   ├── templates/                # Helmfile templates
│   ├── crds.yaml                 # CRDs required by the GitOps stack
│   ├── flux.yaml                 # Flux and Flux operator deployment
│   └── justfile                  # GitOps operation commands
├── env/                          # Environment configurations
│   ├── AZ/
│   │   ├── tfvars.example        # Azure example
│   │   └── <env>/                # Generated env outputs (hosts.ini, ansible.cfg, kubeconfig, keys)
│   ├── OVH/
│   │   ├── tfvars.example        # OVH example
│   │   └── <env>/                # Generated env outputs (hosts.ini, ansible.cfg, kubeconfig, keys)
│   └── KVM/
│       ├── tfvars.example        # Libvirt example
│       └── <env>/                # Generated env outputs (hosts.ini, ansible.cfg, kubeconfig, keys)
│
├── providers/                    # Cloud provider implementations
│   ├── libvirt/                  # Local KVM/QEMU provider
│   │   ├── justfile             # Provider-local Just recipes
│   │   ├── main.tf               # VM provisioning
│   │   ├── variables.tf          # Input variables
│   │   ├── output.tf             # Outputs (IPs, kubeconfig)
│   │   ├── templates.tf          # Cloud-init templates
│   │   ├── keys.tf               # SSH key management
│   │   ├── providers.tf          # Provider configuration
│   │   └── vars_extra.tf         # Optional provider-specific extras
│   ├── azure/                    # Microsoft Azure provider
│   │   ├── justfile             # Provider-local Just recipes
│   │   └── [provider files]
│   ├── ovh/                      # OVH Cloud provider
│   │   ├── justfile             # Provider-local Just recipes
│   │   └── [provider files]
│   │
│   └── shared/                   # Shared resources (all providers)
│       ├── ansible/              # Shared Ansible playbooks (post-deployment steps)
│       │   ├── check_cloudinit.yml
│       │   ├── fetch_kubeconfig.yml
│       │   ├── local.yml
│       │   └── reconciliate_tls.yml
│       ├── cloud-init/           # Cloud-init templates (default, k3s, rke2)
│       │   ├── default/
│       │   │   ├── cloud_init.cfg.tftpl
│       │   │   └── network_config.cfg.tftpl
│       │   ├── k3s/
│       │   │   ├── cloud_init.cfg.tftpl      # k3s deployment template
│       │   │   └── network_config.cfg.tftpl
│       │   └── rke2/
│       │       ├── cloud_init.cfg.tftpl      # rke2 deployment template
│       │       └── network_config.cfg.tftpl
│       └── inventory/
│           └── hosts.tpl         # Ansible inventory template (generated post-deployment)
│
└── assets/                       # Images and documentation assets
    └── InfraFactory.png
```

---

### Optional GitOps Layer

The `gitops/` directory is the optional Kubernetes-side management layer for InfraFactory.

It deploys Flux and tofu-controller into an existing management cluster, then reconciles selected provider/environment OpenTofu stacks from Git. Provider implementation still lives in `providers/`, manual deployment inputs and local artifacts still live in `env/`, and VM/node bootstrap still comes from `providers/shared/cloud-init/`.

Use this layer when you want InfraFactory deployments to be managed by Flux/tofu-controller instead of running `just deploy` locally from the root provider workflow.

Common GitOps commands:

```bash
# Deploy Flux and GitOps controllers
just -f gitops/justfile deploy

# Prepare provider/env secrets and Terraform overlay
PROVIDER=KVM ENV=lab just -f gitops/justfile prepare

# Activate an overlay in the Flux tree
PROVIDER=KVM ENV=lab just -f gitops/justfile activate
```

In this context, GitOps bootstrap is different from cloud-init bootstrap:

- Cloud-init bootstrap initializes VMs and installs `default`, `k3s`, or `rke2` node software.
- The `gitops/` layer initializes and operates the Flux/tofu-controller automation that runs the provider modules.

---

### Workflow: From Code to Running Deployment

```
1. Define infrastructure in env/<PROVIDER>/*.tfvars
   ↓
2. OpenTofu creates VMs with cloud-init configuration
   ↓
3. Cloud-init initializes VMs; k3s/rke2 is installed only for Kubernetes modes
   ↓
4. OpenTofu generates hosts.ini inventory and ansible.cfg in `env/<PROVIDER>/<env>/`
   ↓
5. For Kubernetes modes with enabled user data, Ansible checks cloud-init readiness on K8s nodes
   ↓
6. Ansible reconciles kube-apiserver TLS SAN with public IP and restarts the service (k3s/rke2 only)
   ↓
7. Ansible fetches kubeconfig from first master, rewrites server endpoint to public IP (k3s/rke2 only)
```

**Deployment Flow:**
- You select `cloud_init_selected = "<value>"` in your `.tfvars` where `<value>` can be `[default|k3s|rke2]`
- For VM-only deployments, use `cloud_init_selected = "default"`, `masters.count = 0`, `workers.count = 0`, and `infra.vms.count > 0`
- OpenTofu uses the `providers/shared/cloud-init/<value>/` templates
- These templates are mounted on each VM at boot when that role's `user_data_enabled` is true
- For Kubernetes deployments, Ansible runs post-deployment steps (bounded cloud-init check with a 600-second wait, TLS SAN reconciliation, kubeconfig fetch)
- You can access kubeconfig right after `just deploy` completes for Kubernetes deployments with enabled master user data

---

## Implementation Status

| Provider | Status | Notes |
|----------|--------|-------|
| Libvirt | ✅ Implemented | Core functionality complete, tested |
| Azure | ✅ Implemented | Full implementation with NSG, DNS, and cloud-init |
| OVH | ✅ Implemented | Public-IP-based operator access, deterministic private IP assignment, standalone VMs, VM-only default deployments, kube-api load balancer with native gateway/floating-IP lifecycle and optional SSH jump, full-graph VM replacement, Ansible-based cloud-init check, TLS SAN reconciliation, and kubeconfig fetch |

---

## Governance & Architecture

Infrastructure deployments are governed by the principles in [AGENTS.md](AGENTS.md), enforcing:

- **Core Principles**: Modular design, provider symmetry, consistent workflows
- **Development Priority**: Libvirt (dev) → Azure → OVH
- **Code Quality**: Incremental implementation, focused commits, no system modifications
- **Architecture**: Schema coverage policy, provider parity validation

See [AGENTS.md](AGENTS.md) for AI assistant context and full governance rules.

---

## Known Limitations

- OVH uses public-IP-based operator access even when a private network exists
- OVH standalone `infra.vms` are public-attached and private-attached in current code
- OVH custom root disk sizing and extra disks are not supported yet
- IPv6 support requires additional configuration

<p align="center">
  <img src="assets/InfraFactory.png" alt="Project Logo" width="180">
</p>

<p align="center">
  A provider-agnostic, modular infrastructure factory for deploying multi-cloud clusters with OpenTofu and Ansible.
</p>

---

## Overview

**InfraFactory** is a **reproducible infrastructure framework** designed to provision Kubernetes clusters across multiple environments — locally (KVM/libvirt) or on cloud providers — using a consistent and declarative approach.

It enables you to deploy clusters with varying numbers of control plane (masters) and worker nodes, while supporting multiple Kubernetes distributions.

✨ **Key Features**
- ☁️ **Multi-platform**:    
        - Libvirt (local KVM)    
        - Azure    
- 🌍 **Multi-environment**: One codebase, multiple environments via simple `tfvars` files
- 🔄 **Declarative Infrastructure**: Define your entire cluster in a single configuration
- ⚙️ **Cloud-init** Bootstrap:   
        - Bare virtual machines    
        - Kubernetes via K3s or RKE2    
- 🚀 **Post-Configuration**: Extend and customize nodes using optional ansible-pull for continuous configuration management

**Core Workflow:**
```
OpenTofu (provision VMs) 
  → cloud-init templates (deploy default/k3s/rke2) 
    → inventory generation and kubeconfig import 
      → Ansible-pull (optional post-config)
```

---

## Prerequisites

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

- **OpenTofu** (>= 1.6.0)
  - Install with `arkade get tofu`
  - Or: `apt install opentofu` (Debian/Ubuntu)

- **Just** (>= 1.0.0)
  - Install with `arkade get just`
  - Or: `apt install just` (Debian/Ubuntu)

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
# Deploy cluster
just deploy

# Ping
just ping

# Destroy 
just destroy
```

### 4. Access Your Cluster

After deployment completes, your cluster is **already running** (k3s or rke2 deployed via cloud-init):

```bash
ssh -o StrictHostKeyChecking=no -i ./env/<PROVIDER>/<env>/.key.private localadmin@<ip>
```

The Ansible inventory is generated in `env/<PROVIDER>/<env>/hosts.ini` for any additional configuration tasks.

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


### Configuration Files

Each environment is defined by a `.tfvars` file in `env/<PROVIDER>/`:

**Example: `env/KVM/lab.tfvars`**
```hcl
cluster = {
  id                  = "factory"
  domain              = "lab"
  timezone            = "Europe/Paris"
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

## Project Structure

```txt
InfraFactory/
├── AGENTS.md                     # AI assistant context
├── README.md                     # The only doc, I will produce in my life.
├── TODO.md                       # Task tracking
├── justfile                      # CLI orchestrator (run: just)
├── env/                          # Environment configurations
│   ├── AZ/
│   │   ├── tfvars.example        # Azure example
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
│   ├── ovh/                      # OVH Cloud provider (not started)
│   │   ├── justfile             # Provider-local Just recipes
│   │   └── [provider files]
│   │
│   └── shared/                   # Shared resources (all providers)
│       ├── cloud-init/           # Cloud-init templates (k3s, default bootstrap)
│       │   ├── default/
│       │   │   ├── cloud_init.cfg.tftpl
│       │   │   └── network_config_dhcp.cfg
│       │   └── k3s/
│       │       ├── cloud_init.cfg.tftpl      # k3s deployment template
│       │       └── network_config_dhcp.cfg
│       └── inventory/
│           └── hosts.tpl         # Ansible inventory template (generated post-deployment)
│
└── assets/                       # Images and documentation assets
    └── InfraFactory.png
```

---

### Workflow: From Code to Running Cluster

```
1. Define infrastructure in env/<PROVIDER>/*.tfvars
   ↓
2. OpenTofu creates VMs with cloud-init configuration
   ↓
3. Cloud-init templates mount and deploy k3s (or rke2) on VM boot
   ↓
4. OpenTofu generates hosts.ini inventory from VM IPs, writes ansible.cfg, and imports kubeconfig into `env/<PROVIDER>/<env>/`.
   ↓
5. (Optional) Ansible can perform additional configuration post-deployment
```

**Deployment Flow:**
- You select `cloud_init_selected = "<value>"` in your `.tfvars` where `<value>` can be `[default|k3s|rke2]`
- OpenTofu uses the `providers/shared/cloud-init/<value>/` templates
- These templates are mounted on each VM at boot
- cluster is fully initialized and running **immediately after VM boot** (no additional provisioning needed)
- You can access kubeconfig right after `just deploy` completes

---

## Implementation Status

| Provider | Status | Notes |
|----------|--------|-------|
| Libvirt | ✅ Implemented | Core functionality complete, tested |
| Azure | ✅ Implemented | Full implementation with NSG, DNS, and cloud-init |
| OVH | 🔴 Not Started | Planned for European deployments |

---

## Troubleshooting

### Common Issues

**"tofu init fails: provider not found"**
- Clear cache: `rm -rf providers/<provider>/.terraform`
- Retry: `just validate`

**"SSH key permission denied"**
- Check permissions: `chmod 600 env/<PROVIDER>/<env>/.key.private`

**"Libvirt connection refused"**
- Ensure libvirt is running on the host before using this repository.
- Check socket access with `virsh list` if available in your environment.

**"Inventory hosts.ini not generated"**
- Wait 60+ seconds after deployment (cloud-init initialization)
- Check: `ls -la env/<PROVIDER>/<env>/hosts.ini`

---

## Governance & Architecture

Infrastructure deployments are governed by the [InfraFactory Constitution](.specify/memory/constitution.md), enforcing:

- **Core Principles**: Modular design, provider symmetry, consistent workflows
- **Development Priority**: Libvirt (dev) → Azure → OVH
- **Code Quality**: Incremental implementation, focused commits, no system modifications
- **Architecture**: Schema coverage policy, provider parity validation

See [AGENTS.md](AGENTS.md) for AI assistant context and [constitution.md](.specify/memory/constitution.md) for full governance rules.

---

## Known Limitations

- OVH provider not yet implemented
- OVH top-level orchestration exists, but the provider implementation files are still missing
- Ansible integration is optional (k3s is fully deployed via cloud-init)
- IPv6 support requires additional configuration

<p align="center">
  <img src="assets/InfraFactory.png" alt="Project Logo" width="180">
</p>

<p align="center">
  A provider-agnostic, modular infrastructure factory for deploying multi-cloud clusters with OpenTofu and Ansible.
</p>

---

## Overview

InfraFactory is a **reproducible infrastructure factory** that provisions Kubernetes clusters (and other workloads) across multiple cloud providers from a single codebase.

**Core Workflow:**
```
OpenTofu (provision VMs) → cloud-init templates (deploy k3s/bootstrap) → inventory generation → Ansible (optional post-config)
```

**Key Features:**
- 🎯 **Provider-agnostic**: Same Terraform code works across providers
- 📦 **Modular design**: Reusable cloud-init templates for different deployment types
- ⚡ **Fast iteration**: Local Libvirt provider for rapid development and testing
- ☁️ **Multi-cloud ready**: Deploy to Libvirt, OVH, Azure with minimal changes
- 🔄 **Reproducible**: Deterministic infrastructure from code
- 🚀 **Cloud-init native**: k3s and other services deployed via cloud-init templates (no separate provisioning step)

---

## Prerequisites

- **OpenTofu** (>= 1.6.0)
  - Install from: https://opentofu.org/docs/
  - Or: `apt install opentofu` (Debian/Ubuntu)

- **Just** (>= 1.0.0)
  - Install from: https://github.com/casey/just
  - Or: `apt install just` (Debian/Ubuntu)

- **Provider-specific requirements:**
  - **Libvirt**: KVM/QEMU installed and running (`libvirt-daemon`, `libvirt-dev`)
  - **OVH**: OVH API credentials configured
  - **Azure**: Azure CLI and subscription credentials

---

## Project Structure

```
InfraFactory/
├── AGENTS.md                     # AI assistant context
├── README.md                     # This file
├── TODO.md                       # Task tracking
├── justfile                      # CLI orchestrator (run: just)
├── terraform.tfstate             # Terraform state (git-ignored)
│
├── env/                          # Environment configurations
│   ├── AZ/
│   │   ├── tfvars.example        # Azure example
│   │   └── lab.tfvars            # Azure lab environment
│   └── KVM/
│       ├── tfvars.example        # Libvirt example
│       └── lab.tfvars            # Libvirt lab environment
│
├── providers/                    # Cloud provider implementations
│   ├── libvirt/                  # Local KVM/QEMU provider
│   │   ├── main.tf               # VM provisioning
│   │   ├── variables.tf          # Input variables
│   │   ├── output.tf             # Outputs (IPs, kubeconfig)
│   │   ├── templates.tf          # Cloud-init templates
│   │   ├── keys.tf               # SSH key management
│   │   ├── providers.tf          # Provider configuration
│   │   ├── hosts.ini             # Generated Ansible inventory
│   │   └── ansible.cfg           # Ansible configuration
│   │
│   ├── azure/                    # Microsoft Azure provider
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── output.tf
│   │   ├── templates.tf
│   │   ├── keys.tf
│   │   ├── providers.tf
│   │   └── ansible.cfg
│   │
│   ├── ovh/                      # OVH Cloud provider (not started)
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

### 2. Validate Configuration

```bash
# Validate for Libvirt (default)
just validate

# Or for a specific provider
PROVIDER=AZ just validate
```

### 3. Plan Deployment

```bash
# Preview what will be created
just plan

# For Azure with options
PROVIDER=AZ AZ_SIZE_MATTERS=Standard_B2s just plan
```

### 4. Deploy Infrastructure

```bash
# Deploy cluster (Libvirt by default)
just deploy

# Deploy to Azure
PROVIDER=AZ just deploy

# Deploy to OVH
PROVIDER=OVH just deploy
```

### 5. Access Your Cluster

After deployment completes, your cluster is **already running** (k3s deployed via cloud-init):

```bash
# Get kubeconfig setup command
cd providers/libvirt
terraform output kubeconfig_command

# This will output a command like:
# mkdir -p ~/.kube && \
# ssh -i .key.private ubuntu@<ip> "sudo cat /etc/rancher/k3s/k3s.yaml" | \
# sed 's/127.0.0.1/<ip>/' > ~/.kube/k3s.yaml && \
# chmod 600 ~/.kube/k3s.yaml

# Run that command to set up your kubeconfig
# Then access your cluster:
kubectl get nodes
kubectl get pods --all-namespaces
```

The Ansible inventory is generated in `providers/<PROVIDER>/hosts.ini` for any additional configuration tasks.

### 6. Destroy Infrastructure

```bash
# Destroy Libvirt cluster
just destroy

# Destroy Azure resources
PROVIDER=AZ just destroy
```

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

### Environment Variables

All operations respect these environment variables:

```bash
PROVIDER=KVM      # Cloud provider: KVM (default), AZ, OVH
ENV=lab            # Environment name: lab (default)
```

**Examples:**

```bash
# Use Azure as provider
export PROVIDER=AZ
just validate

# Use OVH
PROVIDER=OVH just plan

# Use specific environment
ENV=prod PROVIDER=AZ just deploy
```

### Configuration Files

Each environment is defined by a `.tfvars` file in `env/<PROVIDER>/`:

**Example: `env/KVM/lab.tfvars`**
```hcl
cluster = {
  name              = "k3s-lab"
  masters           = 1
  workers           = 2
  cloud_init_selected = "k3s"
  username          = "ubuntu"
}

libvirt = {
  cpu    = 4
  memory = 4096
  disk   = 20
}
```

**Example: `env/AZ/lab.tfvars`**
```hcl
azure_subscription_id = "xxxx-xxxx-xxxx"
azure_client_id       = "xxxx-xxxx-xxxx"
azure_client_secret   = "xxxx-xxxx-xxxx"
azure_tenant_id       = "xxxx-xxxx-xxxx"
```

### Workflow: From Code to Running Cluster

```
1. Define infrastructure in env/<PROVIDER>/*.tfvars
   ↓
2. OpenTofu creates VMs with cloud-init configuration
   ↓
3. Cloud-init templates mount and deploy k3s (or other services) on VM boot
   ↓
4. Terraform generates hosts.ini inventory from VM IPs
   ↓
5. (Optional) Ansible can perform additional configuration post-deployment
```

**k3s Deployment Flow:**
- You select `cloud_init_selected = "k3s"` in your `.tfvars`
- OpenTofu uses the `providers/shared/cloud-init/k3s/` templates
- These templates are mounted on each VM at boot
- k3s cluster is fully initialized and running **immediately after VM boot** (no additional provisioning needed)
- You can access kubeconfig right after `just deploy` completes

---

## Provider Details

### Libvirt (Local Development)

**Status:** ✅ In progress

**Best for:** Local development and testing

**Requirements:**
- KVM/QEMU installed
- Libvirt daemon running
- 8+ GB RAM available
- 50+ GB disk space

**Setup:**
```bash
# Ubuntu/Debian
sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-dev

# Start service
sudo systemctl start libvirt-daemon

# Add your user to libvirt group (optional, avoids sudo)
sudo usermod -aG libvirt $USER
```

**Quick deploy:**
```bash
PROVIDER=KVM just deploy
```

### Azure (Enterprise Cloud)

**Status:** 🔄 Not started

**Best for:** Production deployments on Azure

**Requirements:**
- Azure subscription and credentials
- Azure CLI installed
- Proper IAM roles configured

**Setup:**
```bash
# Set Azure credentials
export AZ_SUBS_ID="<subscription-id>"
export AZ_CLIENT_ID="<client-id>"
export AZ_CLIENT_SECRET="<client-secret>"
export AZ_TENANT_ID="<tenant-id>"

# Deploy
PROVIDER=AZ just deploy
```

### OVH (European Cloud)

**Status:** 🔄 Not started

**Best for:** European cloud deployments

**Requirements:**
- OVH account and credentials
- OVH API configured

**Setup:** *(Coming soon)*

---

## Implementation Status

| Provider | Status | Notes |
|----------|--------|-------|
| Libvirt | 🟡 In Progress | Core files ready, end-to-end testing needed |
| OVH | 🔴 Not Started | Planned for production use |
| Azure | 🔴 Not Started | Secondary priority |

---

## Development Roadmap

### Phase 1: Foundation ✅
- [x] Project structure established
- [x] README with full documentation
- [x] TODO tracking

### Phase 2: Libvirt (Priority 1) 🟡
- [x] Provider structure
- [x] Terraform configuration
- [x] Cloud-init templates
- [x] Inventory generation
- [ ] End-to-end testing
- [ ] Documentation

### Phase 3: OVH (Priority 2) 🔴
- [ ] Provider implementation
- [ ] Terraform configuration
- [ ] Testing and validation

### Phase 4: Azure (Priority 3) 🔴
- [ ] Provider implementation
- [ ] Terraform configuration
- [ ] Testing and validation

---

## Troubleshooting

### Common Issues

**"tofu init fails: provider not found"**
- Clear cache: `rm -rf providers/<provider>/.terraform`
- Retry: `just validate`

**"SSH key permission denied"**
- Check permissions: `chmod 600 providers/<provider>/.key.private`

**"Libvirt connection refused"**
- Start daemon: `sudo systemctl start libvirt-daemon`
- Check socket: `virsh list` (should work)

**"Inventory hosts.ini not generated"**
- Wait 60+ seconds after deployment (cloud-init initialization)
- Check: `ls -la providers/<provider>/hosts.ini`

---

## Governance & Architecture

Infrastructure deployments are governed by the [InfraFactory Constitution](.specify/memory/constitution.md), enforcing:

- **Core Principles**: Modular design, provider symmetry, consistent workflows
- **Development Priority**: Libvirt (dev) → OVH (production) → Azure
- **Code Quality**: Incremental implementation, focused commits, no system modifications
- **Architecture**: Schema coverage policy, provider parity validation

See [AGENTS.md](AGENTS.md) for AI assistant context and [constitution.md](.specify/memory/constitution.md) for full governance rules.

---

## Known Limitations

- DigitalOcean support removed from roadmap (out of scope)
- OVH and Azure providers not yet implemented
- Ansible integration is optional (k3s is fully deployed via cloud-init)
- IPv6 support requires additional configuration

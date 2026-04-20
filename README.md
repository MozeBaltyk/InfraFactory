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
│       ├── cloud-init/           # Cloud-init templates (default, k3s, rke2)
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
| OVH | ✅ Implemented | Public-IP-based operator access, deterministic private IP assignment, kube-api load balancer, and floating-IP cleanup helper |

---

## Troubleshooting

### Libvirt state migration after the `libvirt_domain.vms` refactor and node naming changes

If you already have an existing libvirt workspace created before the `count` → `for_each` refactor and before the `${var.cluster.id}-nodeNN` serial naming scheme, move the old state addresses before your next `plan`/`apply`.

Replace `<cluster-id>` with your real `var.cluster.id` value:

```bash
cd providers/libvirt
tofu workspace select <env>

tofu state mv 'libvirt_domain.masters[0]' 'libvirt_domain.vms["<cluster-id>-node01"]'
tofu state mv 'libvirt_domain.masters[1]' 'libvirt_domain.vms["<cluster-id>-node02"]'
tofu state mv 'libvirt_domain.workers[0]' 'libvirt_domain.vms["<cluster-id>-node03"]'
tofu state mv 'libvirt_domain.workers[1]' 'libvirt_domain.vms["<cluster-id>-node04"]'

tofu state mv 'libvirt_volume.resized_os_image["master01"]' 'libvirt_volume.resized_os_image["<cluster-id>-node01"]'
tofu state mv 'libvirt_volume.resized_os_image["master02"]' 'libvirt_volume.resized_os_image["<cluster-id>-node02"]'
tofu state mv 'libvirt_volume.resized_os_image["worker01"]' 'libvirt_volume.resized_os_image["<cluster-id>-node03"]'
tofu state mv 'libvirt_volume.resized_os_image["worker02"]' 'libvirt_volume.resized_os_image["<cluster-id>-node04"]'

tofu state mv 'libvirt_cloudinit_disk.commoninit["master01"]' 'libvirt_cloudinit_disk.commoninit["<cluster-id>-node01"]'
tofu state mv 'libvirt_cloudinit_disk.commoninit["master02"]' 'libvirt_cloudinit_disk.commoninit["<cluster-id>-node02"]'
tofu state mv 'libvirt_cloudinit_disk.commoninit["worker01"]' 'libvirt_cloudinit_disk.commoninit["<cluster-id>-node03"]'
tofu state mv 'libvirt_cloudinit_disk.commoninit["worker02"]' 'libvirt_cloudinit_disk.commoninit["<cluster-id>-node04"]'
```

Repeat the same pattern for every existing node and for any `libvirt_volume.extra_disks["<old-name>-<index>"]` entries.

`tofu state mv` only updates OpenTofu state addresses. Because the libvirt domain, cloud-init ISO, and disk names also change, an existing deployment can still show replacements on the next plan unless the underlying libvirt objects are recreated or otherwise renamed to match the new names.

Changing `cluster.node_name_format` later also changes VM, disk, and cloud-init object names, so existing libvirt resources will usually need state moves or recreation.

In `serial` mode, changing `infra.masters.count` does more than renumber workers: it can cause the same `${cluster.id}-nodeNN` identity to move from worker to master or from master to worker as the topology changes. Because those names are also OpenTofu `for_each` keys, this can lead to destructive or confusing lifecycle behavior for existing deployments.

If you expect to scale masters and workers independently over time, prefer `role` mode. In `role` mode, changing `infra.masters.count` does not renumber workers, but changing either role count can still add, remove, or recreate nodes for that role.

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

- OVH uses public-IP-based operator access even when a private network exists
- OVH multi-master requires `network.cidr`
- OVH private networking and the kube-api load balancer are currently coupled
- OVH multi-node readiness can still be inconsistent in some scenarios
- OVH cleanup of gateway or other implicit public IP leftovers outside the captured load-balancer floating IP still depends on OVH/provider behavior
- OVH custom root disk sizing and extra disks are not supported yet
- Ansible integration is optional (k3s is fully deployed via cloud-init)
- IPv6 support requires additional configuration

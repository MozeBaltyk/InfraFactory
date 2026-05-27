# OVH Provider — Infrastructure and Network Architecture

## Overview

The OVH provider in InfraFactory provisions Kubernetes clusters on **OVH Public Cloud**.  
It follows the same modular, provider-agnostic principles as the Libvirt and Azure providers but adapts to OVH's specific networking primitives: **private networks on OpenStack**, **native load balancers with floating IPs**, and **public-IP-based instance access**.

---

## Provisioning Workflow

```
User (just deploy)
  │
  ├── 1. tofu init / workspace select
  ├── 2. tofu apply -var-file=env/OVH/<ENV>.tfvars
  │
  │   OpenTofu creates:
  │   ├── SSH key (ovh_cloud_project_ssh_key)
  │   ├── Private network + subnet
  │   ├── N master instances (public + private NICs)
  │   ├── M worker instances (public + private NICs)
  │   ├── [Optional] Load Balancer + gateway + floating IP
  │   └── Local artifacts (hosts.ini, ansible.cfg, .key.private, kubeconfig)
  │
  ├── 3. Ansible: check_cloudinit.yml
  ├── 4. Ansible: reconciliate_tls.yml (k3s/rke2, adds public endpoint to TLS SAN)
  └── 5. Ansible: fetch_kubeconfig.yml (k3s/rke2, rewrites server endpoint)
```

---

## Resources Created on OVH

### 1. SSH Key (`ovh_cloud_project_ssh_key`)

- Generated from a TLS private key (RSA 4096) created in `keys.tf`.
- Uploaded to the OVH project so it can be injected into VMs.
- Named `${terraform.workspace}-<random_hex_suffix>`.

### 2. Private Network (`ovh_cloud_project_network_private`)

- A **vLAN-encapsulated** private layer-2 network in the target region.
- Named `${var.cluster.id}-private`.
- All instances are attached to this network.

### 3. Private Subnet (`ovh_cloud_project_network_private_subnet_v2`)

- Created on the private network.
- Configured with:
  - **DHCP enabled** — the subnet serves IPs, but Terraform pins each VM to a specific IP.
  - **Gateway IP enabled** — OVH creates a gateway that provides outbound internet access from the private network (required for the load balancer's `gateway_create`).
  - **Default DNS resolver** enabled — VMs can use OVH's internal DNS.

### 4. Master Instances (`ovh_cloud_project_instance`)

| Property | Value |
|----------|-------|
| Billing | Hourly |
| Image | Selected dynamically from `ovh_cloud_project_images` data source via OS search patterns (e.g., `ubuntu` + `24.04`) |
| Flavor | Configurable per role (`instance_size`, e.g. `b2-7`) |
| Root disk | 40 GB (custom sizing not yet supported) |
| Extra disks | Not yet supported (blocked by validation) |
| SSH key | Injected via OVH's `ssh_key` block |
| Public NIC | Always enabled (`public = true`) |
| Private NIC | Attached to the private subnet with a **deterministic private IP** |

### 5. Worker Instances (`ovh_cloud_project_instance`)

- Same schema as masters.
- Count is independent of masters.
- Private IPs are assigned **after** all master IPs in the CIDR offset range.

### 6. Optional: Load Balancer (`ovh_cloud_project_loadbalancer`)

Created only when `network.kube_api.load_balancer.enabled = true`.

| Property | Value |
|----------|-------|
| Name | `${var.cluster.id}-kube-api` |
| Flavor | Configurable (`small`, `medium`, `large`, `xl`) |
| Region | Same as cluster |
| Listener | TCP 6443 → backend pool |
| Pool algorithm | `roundRobin` |
| Pool protocol | TCP |
| Health monitor | TCP check every 5 s, 3 retries, 3 s timeout |
| Network | Private (attached to the private subnet) |

**Side effects of LB creation:**
- `gateway_create` — OVH transparently creates a **gateway** on the subnet to allow the LB to reach the internet (and vice versa).
- `floating_ip_create` — OVH allocates a **floating IP** that serves as the public Kubernetes API endpoint.

**Cleanup concern:** Neither the gateway nor the floating IP is cascade-deleted when the LB is destroyed.  
A destroy-time provisioner (`null_resource.private_network_destroy_grace`) calls `cleanup_gateway.py` to remove both.

---

## Network Architecture

### Dual-NIC Design

Every OVH instance has **two network interfaces**:

| Interface | OVH Name | Purpose |
|-----------|----------|---------|
| `ens3` | Public NIC | Default route, public IPv4, SSH access |
| `ens4` | Private NIC | Static private IP on the private subnet |

### Public Side

- **Public = true** on every `ovh_cloud_project_instance`.
- Each VM receives a public IPv4 address from OVH's public IP pool.
- Used for:
  - SSH access to nodes
  - Ansible inventory (`hosts.ini` uses public IPs)
  - Cloud-init readiness check
  - TLS SAN reconciliation
  - Kubeconfig retrieval
- **This is the operator access plane.**

### Private Side

- A private network + subnet is **always created** (the schema requires `network.private.cidr`).
- Each VM receives a private IPv4 address pinned explicitly by Terraform (not dynamically from DHCP).
- Used for:
  - Master-to-master cluster traffic (etcd, control plane)
  - Worker-to-master join traffic
  - Load balancer backend members (masters on TCP 6443)
  - Cloud-init `node-ip` and `advertise-address` settings
- **This is the cluster data plane.**

### Why Deterministic Private IPs Instead of DHCP

Although the subnet has DHCP enabled, private IPs are **pre-computed** using `cidrhost()` because:

1. The first master's private IP is the **cluster join endpoint** — it must be known before VMs exist.
2. Cloud-init templates embed the private IP for `node-ip` and `advertise-address`.
3. The load balancer backend pool lists master private IPs as static members.
4. Multiple resources (cloud-init, LB, templates) must reference the **same IPs** at plan time.

DHCP on the subnet merely serves the IP that Terraform assigns — it is **not** the source of truth for addressing.

### Private IP Allocation Strategy

```hcl
cidr = "10.0.0.0/24"  # example

host_offset_base = (prefix_length <= 28 ? 10 : 2)

master_ips = [
  cidrhost(cidr, offset + 0)  # master 1  → 10.0.0.10
  cidrhost(cidr, offset + 1)  # master 2  → 10.0.0.11
  ...
]

worker_ips = [
  cidrhost(cidr, offset + masters_count + 0)  # worker 1  → 10.0.0.13 (after 3 masters)
  cidrhost(cidr, offset + masters_count + 1)  # worker 2  → 10.0.0.14
  ...
]
```

- **Normal subnets** (prefix ≤ 28): offset starts at **10** — leaves `.1`–`.9` free for gateways, DHCP pool, etc.
- **Tight subnets** (prefix > 28): offset starts at **2** — conserves scarce addresses.

This ensures:
- Deterministic node-to-IP mapping
- Reproducible backend membership
- No collision with OVH gateway or DHCP reserved addresses

---

## Traffic Flow Diagrams

### Minimal (Private network only, no LB)

```
Operator
  │
  ├── SSH/Ansible ──► Public IP master ──► cloud-init / kubeconfig
  │
  Masters ──► Private network (internal traffic, join, etcd)
  │
  Workers ──► Private network ──► First master private IP (join)
```

- Kubeconfig endpoint: **first master public IP**
- TLS SAN includes: first master private IP, first master FQDN, all master FQDNs

### With Load Balancer

```
Operator (kubectl)
  │
  ├── SSH/Ansible ──────────────────► Public IP of each node
  │
  ├── kubectl ──► LB Floating IP ──► Masters:6443 (via private network)
  │                    │
  │                    └── OVH Gateway ──► Internet (NAT for private subnet)
  │
  Masters ──► Private network (etcd, control plane, join)
  │
  Workers ──► Private network ──► First master private IP (join)
```

- Kubeconfig endpoint: **LB floating IP** (or DNS name, or literal value)
- TLS SAN includes: LB floating IP, all master private IPs, all master FQDNs
- LB health monitor: TCP 6443 check against each master every 5 s

### Multi-Master (3 masters, 0 workers)

```
              ┌── Master 1 (public + private)
              │
  Operator ───┼── Master 2 (public + private)
              │
              └── Master 3 (public + private)

  Masters ──► Private network for etcd consensus
  Masters ──► First master private IP as join endpoint
```

- `network.private.cidr` **required** (enforced by `checks.tf`).
- Etcd runs on all masters over the private network.

---

## Kubernetes API Endpoint Resolution

The `public_kube_api_endpoint` local variable determines the advertised Kubernetes API address with this priority:

| Priority | Condition | Endpoint |
|----------|-----------|----------|
| 1 | `endpoint = "lb_ip"` **and** LB exists | LB floating IP address |
| 2 | `endpoint` is neither `"lb_ip"` nor `"dns"` | The literal value of `endpoint` |
| 3 | `endpoint = "dns"` **and** `dns.name` is set | The DNS name (must exist outside Terraform) |
| 4 | Fallback | First master's public IP |
| 5 | Last resort | First master's private IP |

**Note:** `endpoint = "dns"` does **not** disable load balancer creation. It only changes which address is written into the kubeconfig and TLS SAN.

---

## Instance Topology

### Name Format

Two naming modes controlled via `cluster.node_name_format`:

**Serial mode** (`"serial"`, default):
```text
factory-node01   # master 1
factory-node02   # master 2
factory-node03   # worker 1  (continues after masters)
factory-node04   # worker 2
```

**Role mode** (`"role"`):
```text
factory-m01      # master 1
factory-m02      # master 2
factory-w01      # worker 1
factory-w02      # worker 2
```

### FQDN

Every node gets a fully qualified domain name:
```
<name>.<cluster.id>.<cluster.domain>
# Example: factory-node01.factory.lab
```

---

## Cloud-Init Integration

OVH reuses the **shared cloud-init templates** from `providers/shared/cloud-init/<type>/`:

| Template Set | File | Purpose |
|---|---|---|
| `default` | `cloud_init.cfg.tftpl` | Base VM setup (user, SSH, hostname, packages) |
| `k3s` | `cloud_init.cfg.tftpl` | Base + K3s bootstrap/join |
| `rke2` | `cloud_init.cfg.tftpl` | Base + RKE2 bootstrap/join |

All sets also render the shared `network_config.cfg.tftpl` for the private NIC.

### OVH-Specific Cloud-Init Merge

OVH's `templates.tf` performs a **YAML-based merge** of the shared cloud-init template with OVH-specific additions:

1. **Writes a netplan file** at `/etc/netplan/99-infrafactory-private.yaml` for the private NIC (`ens4`).
2. **Injects a `bootcmd`** to apply the netplan early (before SSH starts).
3. **Merges `write_files`** — the shared template's files plus the OVH netplan file.

### Private NIC Netplan

The generated netplan for `ens4` uses:
- **DHCP** enabled (to receive the IP reserved by Terraform on the OpenStack port).
- **`use-routes: false`** — prevents OVH's DHCP from injecting a default route on the private NIC.
- **`use-dns: false`** — prevents DNS from the private DHCP from competing with the public NIC's DNS.

This is critical because without it, the DHCP server (with `enable_gateway_ip = true`) advertises a default route on `ens4`, causing **asymmetric routing** that breaks inbound SSH on the public IP.

---

## Bootstrap and Post-Deployment Steps

| Step | Component | What Happens |
|------|-----------|-------------|
| 1 | OpenTofu apply | Creates all OVH resources |
| 2 | Cloud-init | Each VM boots, applies netplan, installs packages, runs k3s/rke2 install script |
| 3 | `time_sleep.wait_instance_networks` | 30 s delay for OVH API to populate public IPs |
| 4 | `terraform_data.validate_public_ips` | Precondition: all VMs must have a public IP |
| 5 | `local_file.ansible_inventory` | Generates `env/OVH/<env>/hosts.ini` |
| 6 | `null_resource.check_cloudinit` | Ansible playbook `check_cloudinit.yml` — waits for cloud-init completion |
| 7 | `null_resource.reconcile_tls_san` | Ansible playbook `reconciliate_tls.yml` — adds public endpoint to TLS SAN (k3s/rke2) |
| 8 | `null_resource.fetch_kubeconfig` | Ansible playbook `fetch_kubeconfig.yml` — downloads kubeconfig, rewrites server endpoint |

---

## Local Artifacts Generated

After deployment, under `env/OVH/<workspace>/`:

| File | Content |
|------|---------|
| `.key.private` | RSA 4096 private key (0600 permissions) |
| `.key.pub` | RSA 4096 public key (OpenSSH format) |
| `.token` | Cluster join token (random or user-provided) |
| `ansible.cfg` | Ansible configuration pointing to local inventory and key |
| `hosts.ini` | Ansible inventory with controller and worker groups (public IPs) |
| `kubeconfig` | Kubernetes config with public API endpoint (k3s/rke2 only) |

---

## Destroy Cleanup

### The `cleanup_gateway.py` Script

An OVH-specific destroy-time helper at `providers/ovh/cleanup_gateway.py`.

**Problem:** When the load balancer is destroyed:
1. The **gateway** created by `gateway_create` remains attached to the subnet, blocking subnet deletion.
2. The **floating IP** created by `floating_ip_create` remains allocated (still billable).

**Solution:** A `null_resource` with a destroy-time `local-exec` provisioner calls the script.

The script:
1. Connects to the OVH API using credentials from environment variables.
2. Finds the gateway by name and deletes it via `DELETE /cloud/project/{sn}/region/{r}/gateway/{id}`.
3. Finds the floating IP by description and deletes it via `DELETE /cloud/project/{sn}/region/{r}/floatingip/{id}`.
4. Polls the resulting operations until completion.
5. Skips gracefully if the resources don't exist.

**Dependency chain on destroy:**  
`LB → VMs → private_network_destroy_grace (cleanup) → subnet → private network`

---

## Current Limitations

| Limitation | Impact | Status |
|------------|--------|--------|
| Custom root disk sizing | All VMs get 40 GB root disk | Not supported (validated) |
| Extra disks (additional block storage) | Cannot attach data disks | Not supported (validated) |
| Public-IP-based inventory | Even with private network, `hosts.ini` uses public IPs | By design |
| Multi-master requires private network | No private CIDR = only 1 master allowed | Enforced by `checks.tf` |
| LB gateway/floating IP not cascade-deleted | Destroy needs Python `cleanup_gateway.py` | Workaround via local-exec |
| Some multi-node readiness timing | Rare race conditions in public IP propagation after 30 s delay | Known intermittent |

---

## Deployment Examples

### Single Master, No Workers, No LB (k3s)

```hcl
cluster = {
  id                  = "k3s-1m"
  domain              = "ovh"
  region              = "GRA9"
  username            = "localadmin"
  cloud_init_selected = "k3s"
}

infra = {
  masters = { count = 1 }
  workers = { count = 0 }
}

network = {
  private = { cidr = "10.0.20.0/24" }
}
```

### 1 Master, 2 Workers with LB (k3s)

```hcl
cluster = {
  id                  = "k3s-1m2w"
  domain              = "ovh"
  region              = "GRA9"
  username            = "localadmin"
  cloud_init_selected = "k3s"
}

infra = {
  masters = { count = 1 }
  workers = { count = 2 }
}

network = {
  private = { cidr = "192.168.112.0/24" }
  kube_api = {
    endpoint = "lb_ip"
    load_balancer = { enabled = true, flavor = "small" }
  }
}
```

### 3 Masters, RKE2

```hcl
cluster = {
  id                  = "rke2-3m"
  domain              = "ovh"
  region              = "GRA9"
  username            = "localadmin"
  cloud_init_selected = "rke2"
}

infra = {
  masters = { count = 3 }
  workers = { count = 0 }
}

network = {
  private = { cidr = "10.0.23.0/24" }
}
```

---

## Comparison with Other Providers

| Aspect | OVH | Azure | Libvirt |
|--------|-----|-------|---------|
| VM access | Public IP | Public IP | NAT/bridge IP or FQDN |
| Private networking | OVH private network (vLAN) | Azure VNet + subnet | Libvirt NAT/bridge network |
| Private IP assignment | Deterministic (`cidrhost`) | Dynamic (Azure DHCP) | Static or DHCP |
| kube-api exposure | Optional LB + floating IP | Optional LB (via NSG + PIP) | Direct node IP or port-forward |
| Extra disks | Not yet supported | Supported (LUN) | Supported (SCSI + WWN) |
| Custom root disk | Not yet supported | Supported | Supported |
| DNS management | External (not managed) | Azure Private DNS Zone | Libvirt DNS or external |
| GitOps support | Standard (env directory) | Standard | Extended (gitops_artifacts_mode) |
| Destroy cleanup | `cleanup_gateway.py` needed | None needed | None needed |

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `providers/ovh/main.tf` | VM creation, image/flavor discovery, IP validation |
| `providers/ovh/variables.tf` | All input variables and locals (IP calculation, topology, kubeconfig endpoint) |
| `providers/ovh/network.tf` | Private network, subnet, LB, destroy-time gateway cleanup |
| `providers/ovh/templates.tf` | Cloud-init rendering, netplan injection, ansible.cfg |
| `providers/ovh/output.tf` | hosts.ini generation, Terraform outputs |
| `providers/ovh/keys.tf` | SSH key pair, cluster token |
| `providers/ovh/ansible.tf` | Post-deployment Ansible playbook orchestration |
| `providers/ovh/checks.tf` | Deploy-time precondition checks |
| `providers/ovh/extra_vars.tf` | k3s, rke2, ansible-pull, extra_packages variables |
| `providers/ovh/providers.tf` | OVH provider configuration |
| `providers/ovh/cleanup_gateway.py` | Destroy-time LB gateway + floating IP cleanup |
| `providers/ovh/justfile` | Provider-local Just recipes |
| `providers/ovh/README.md` | Current implementation findings and design decisions |
| `providers/shared/cloud-init/` | Shared cloud-init templates consumed by all providers |
| `providers/shared/inventory/hosts.tpl` | Ansible inventory template |
| `env/OVH/tfvars.example` | Canonical deployment input template |
| `env/OVH/<env>.tfvars` | Environment-specific deployments |

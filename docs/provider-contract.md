# Provider Contract

This document is the canonical specification of the provider interface that
every provider module (`libvirt`, `azure`, `ovh`) MUST implement.

Per-capability implementation details and test matrix live in
`providers/README`. This file is the contract; that file is the evidence.

## Provider Directory Layout

Every provider directory (`providers/{libvirt,azure,ovh}/`) follows the same
layout. Files present in all providers:

```text
provider/
├── ansible.tf       # ansible-artifacts module wiring, kubeconfig/reconcile flow
├── keys.tf          # ssh-keys module wiring (keypair + token)
├── main.tf          # VM provisioning
├── output.tf        # cluster_nodes, kubeconfig_command, provider outputs
├── providers.tf     # provider configuration
├── templates.tf     # cloud-init rendering, network config
├── variables.tf     # variable schema (shared + provider-specific)
├── vars_extra.tf    # provider-specific variable extensions
└── justfile         # provider-local recipes (validate/plan/deploy/...)
```

Provider-specific files, present only where the capability exists:

```text
├── network.tf       # subnets, security groups, LB, gateway/FIP (OVH)
├── bastion.tf       # dedicated bastion + jump-mode SGs (OVH)
├── checks.tf        # deploy-time validation (OVH)
├── talos.tf         # talos-cluster module wiring (libvirt)
├── moved.tf         # state-move records (OVH)
```

Shared assets outside the provider directories:

```text
providers/shared/
├── ansible/                    # shared playbooks (check_cloudinit, reconcile_tls, fetch_kubeconfig)
├── cloud-init/$type/           # cloud_init.cfg + network_config templates
├── inventory/hosts.tpl         # common inventory template → hosts.ini
└── modules/
    ├── ssh-keys/
    ├── cloudinit-renderer/
    ├── ansible-artifacts/
    └── talos-cluster/
```

Provider-specific behavior must be added to the provider directory, not by
forking shared assets.

## Common Capabilities Baseline

### SSH & Secrets

- Generate an RSA 4096-bit SSH key pair.
- Write keys to `env/<PROVIDER>/<workspace>/`.
- Talos mode does not generate SSH keys or k3s/rke2 tokens.

### Compute Topology

- N masters, N workers, and N standalone VMs, independently configurable.
- Separate `masters`, `workers`, and `vms` objects in the variable schema.
- Per-role compute sizing: CPU / RAM / disk size.
- Per-role extra disks (structured): `size_gb`, `mount_path`, `filesystem`,
  `label`.
- Scale up/down by adding or removing VMs.
- VM-only `default` deployments: `cloud_init_selected = "default"`,
  `masters.count = 0`, `workers.count = 0`, `vms.count >= 1`.

### Cloud-Init

- Selectable variant via `cluster.cloud_init_selected`: `default`, `k3s`,
  `rke2`; Talos replaces cloud-init/Ansible where supported (libvirt).
- Cloud-init sources MUST reference `providers/shared/cloud-init/$type/`.
- Inject username + SSH public key.
- Optional OS upgrade control via `cluster.package_upgrade_enabled`.
- Per-role `user_data_enabled`; when disabled, no cloud-init is injected for
  that role.
- Optional inputs: `extra_packages`; `k3s` block (version, token, tls_sans,
  etcd/traefik/servicelb/local-storage/metrics-server/flannel toggles);
  `rke2` block (version, token, tls_sans, etcd/ingress-nginx/metrics-server
  toggles); cluster token auto-generation (`.token` file); `ansible.pull`
  block (repo, branch, playbook, token, timer).

### Ansible Integration

- Inventory output compatible with `providers/shared/inventory/hosts.tpl`.
- Inventory contains shared `CONTROLLERS`, `WORKERS`, and `VMS` groups.
- Generate `ansible.cfg` with remote user, inventory path, private key.
- Kubernetes post-deployment playbooks (shared, gated by cloud-init mode and
  role `user_data_enabled`):
  - cloud-init readiness check (`timeout 600 cloud-init status --wait`)
  - TLS SAN reconciliation (k3s/rke2)
  - kubeconfig fetch with endpoint rewrite (k3s/rke2)
- VM-only `default` deployments generate inventory and SSH artifacts but skip
  Kubernetes post-steps.

### Outputs

- `cluster_nodes` — normalized connection data:
  `controller_ips`, `worker_ips`, `vm_ips`, `public_ips`, `private_ips`,
  plus `nodes` — full §5 node objects per VM:
  `name`/`role`/`private_ip`/`public_ip`/`operator_address`/`bootstrap_endpoint`.
- `kubeconfig_command` — command to use the generated kubeconfig when
  Kubernetes is enabled.
- Kubernetes API endpoint output or nested detail where supported.

### Cluster Identity

- `cluster.id` for resource naming.
- `cluster.domain` for DNS naming.
- `cluster.node_name_format`: `"serial"` (shared sequence) or `"role"`
  (per-role sequence).

## Provider-Specific Extensions

Allowed only where technically required:

| Provider | Extensions |
|---|---|
| Azure | NSG rules (port/name/description/source_address); Azure Private DNS Zone + A records; Azure-native networking (no cloud-init network config); LUN-based extra disks; `os_catalog.hostname_prefix` |
| Libvirt | Per-role optional `ip_addresses` / `mac_addresses`; network mode `nat` / `route` / `bridge`; `ip_type` `dhcp` / `static`; gateway derivation; `network.extra_dns`; storage pool `cluster.factory_root_path`; cloud-init via ISO; `gitops_artifacts_mode` |
| OVH | Dedicated bastion (`ssh_jump_enabled`) with private-only cluster nodes; OVH Public Cloud Load Balancer (Octavia) + managed gateway + floating IP; private network + subnet with deterministic private IPs; cluster-owned OpenStack security groups; operator ingress CIDRs |

## Dependency Direction

Providers implement infrastructure; shared logic consumes a normalized node
model. Never make shared Talos/K3s/RKE2 logic depend directly on a provider
resource unless unavoidable.

## Validation Expectations

Provider changes must preserve or extend the documented provider test matrix
in `providers/README`. At minimum:

- single-master k3s flow
- HA-style multi-master + workers flow
- both `k3s` and `rke2` cloud-init modes
- VM-only `default` flow with standalone `infra.vms`
- generated inventory and kubeconfig artifacts under
  `env/<PROVIDER>/<workspace>/` when applicable

## Changing the Contract

When changing a shared contract:

1. identify affected providers;
2. update shared types/modules;
3. update each provider;
4. update tests;
5. update documentation — including `env/<PROVIDER>/tfvars.example`.
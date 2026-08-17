# Provisioning Lifecycle

This document describes the phases of an InfraFactory deployment and the
ordering guarantees each provider must honor. It follows the logical phase
model from `docs/architecture.md` (§7).

The whole flow is orchestrated through the root `justfile`:

```text
just validate → just plan → just deploy → just check → just destroy
```

Mapping: `validate`/`plan` = Phase 0; `deploy` = Phases 1–5; `check` = Phase 6.

---

## Phase 0 — Configure, Validate & Plan

- Write `env/<PROVIDER>/<environment>.tfvars` (template:
  `env/<PROVIDER>/tfvars.example`).
- Provider credentials:
  - Azure: `azure_subscription_id` / client id / secret / tenant.
  - OVH: OVH API keys (+ OpenStack `OS_*` for security groups) — sourced via
    `env/OVH/openrc.sh` or the OVH justfile `_source-openrc`.
  - Libvirt: local `qemu:///system` (or `qemu+ssh://`).
- `just validate` runs `tofu validate` and deploy-time checks (OVH `checks.tf`):
  multi-master requires private CIDR, LB requires private CIDR, LB flavor
  exists, CIDR provides enough IPs.
- `just plan` produces the apply plan; the justfile renders the tfvars path
  and sources OpenRC when needed.

---

## Phase 1 — Network

Create networks, subnets, routing, security groups, and load balancers.

Dependency order (all providers):

```text
tfvars
  ↓
network / subnet / security groups
  ↓
SSH keys + cluster token (shared module)
```

Provider notes:

- **Azure** — VNet/subnet from `network.cidr`, Private DNS Zone + A records,
  NSG rules.
- **Libvirt** — network (nat/route/bridge), optional `extra_dns`, gateway
  derivation, DHCP/static.
- **OVH** — private network + subnet with deterministic private IPs;
  cluster-owned OpenStack security groups (bastion SG + private cluster SG in
  jump mode); LB mode adds:

```text
[gateway → LB → floating IP]   (OVH LB mode)
```

Ordering guarantees (OVH, LB mode):

- Load balancer deletion happens before gateway/FIP deletion; gateway
  deletion happens before the managed subnet.
- The gateway is replaced when the VM generation changes
  (`terraform_data.gateway_vm_generation` barrier), so a full-graph replace
  keeps LB/gateway/FIP consistent.

---

## Phase 2 — Compute

Create VMs and disks:

- bastion (OVH jump mode)
- masters / control-plane nodes
- workers
- standalone VMs (`infra.vms`)
- disks (root + structured extra disks)

Roles are modeled separately with per-role sizing (CPU/RAM/disk, extra
disks) and per-role `user_data_enabled` toggles. Nodes are named per
`cluster.node_name_format` (`serial` or `role`).

---

## Phase 3 — Bootstrap transport

Establish whatever connectivity the provisioning system requires, and the
inventory that encodes it.

```text
Libvirt → direct node connectivity

Azure → public/private endpoint depending on configuration

OVH → direct, or SSH forwarding (jump) through the dedicated bastion
```

This phase provides **deterministic per-node connectivity**.

- Each provider renders the Ansible inventory
  (`providers/shared/inventory/hosts.tpl`) into
  `env/<PROVIDER>/<workspace>/`:
  - `hosts.ini` (shared `CONTROLLERS` / `WORKERS` / `VMS` groups)
  - `ansible.cfg` (remote user, inventory path, private key, host-key policy)
- OVH jump mode: connectivity is embedded in `ansible.cfg` / output commands
  via a self-contained `ProxyCommand` through the bastion — no `ssh_config`
  file is generated (see `docs/networking.md`).
- The transport is validated with a **cloud-init readiness gate**
  (`timeout 600 cloud-init status --wait` on all nodes): the deploy fails if
  any node never becomes reachable and ready.

---

## Phase 4 — Cluster bootstrap

Cluster-specific implementation executes on the reachable nodes.

```text
Talos (libvirt)
  ├── machine configuration (talos-cluster module)
  ├── bootstrap etcd
  └── obtain kubeconfig

K3s
  └── cloud-init / Ansible

RKE2
  └── cloud-init / Ansible
```

For k3s/rke2, VMs boot with the selected cloud-init variant from
`providers/shared/cloud-init/$type/` (`default`, `k3s`, `rke2`):

- SSH key + username injection
- base packages / optional upgrade (`package_upgrade_enabled`)
- hostname configuration
- cluster installer download and join

Cloud-init keeps operating-system setup; cluster configuration belongs to
Ansible.

VM-only `default` deployments (no masters/workers) stop after bootstrap
transport — no cluster bootstrap occurs.

---

## Phase 5 — Day-2 endpoints

Once the cluster is healthy, operational tooling switches to **stable**
management and Kubernetes endpoints.

Shared Ansible playbooks (gated by cloud-init mode and role
`user_data_enabled`):

1. **TLS SAN reconciliation** (k3s/rke2) — add the public/LB endpoint to
   kube-apiserver certs; restart serially across controllers.
2. **kubeconfig fetch** (k3s/rke2) — pull kubeconfig from the first master;
   rewrite the server endpoint to the stable Kubernetes endpoint.

Talos: the generated `talosconfig` MUST contain the management endpoint, not
temporary bootstrap tunnels (`bootstrap_endpoint != management_endpoint`).

Bootstrap endpoints MUST NOT leak into final user-facing configuration
unless intentionally required.

---

## Phase 6 — Artifacts and validation

Generate and validate the final artifacts:

```text
env/<PROVIDER>/<environment>/
├── hosts.ini
├── ansible.cfg
├── kubeconfig
├── talosconfig        (Talos mode, libvirt)
├── .key.private
└── .key.pub
```

Only applicable artifacts are generated. Generated artifacts MUST NOT be
written into `providers/`.

Validation:

- `just check` inspects the generated artifacts / cluster state.
- Manual: `export KUBECONFIG=env/<PROVIDER>/<env>/kubeconfig` then
  `kubectl get nodes`.

---

## OVH Dedicated-Bastion Workflow (Private-Only Nodes)

End-to-end walkthrough for `ssh_jump_enabled = true` mode, where masters and
workers have **no public IP** and are reached only through the bastion.
Mechanics (topology, security groups, transport) are in `docs/networking.md`;
full variable surface in `env/OVH/tfvars.example`.

1. **Configure** — in `env/OVH/<env>.tfvars`:
   - `network.private.cidr` + optional `vlan_id`
   - `network.kube_api.load_balancer.enabled = true` with `ssh_jump_enabled =
     true` (flavor/gateway_model as needed)
   - `network.kube_api.endpoint` (e.g. `lb_ip`) + operator `ingress_cidrs`
2. **Validate & plan** — `PROVIDER=OVH ENV=<env> just validate && just plan`;
   review the authenticated plan before applying.
3. **Deploy** — `just deploy`. Creates: bastion (public+private), private-only
   masters/workers, LB (TCP/6443) + gateway + floating IP, bastion/cluster
   security groups. The cloud-init readiness gate, TLS SAN reconciliation, and
   kubeconfig fetch run automatically (Phase 3–5).
4. **Connect**:
   - Kubernetes: `export KUBECONFIG=env/OVH/<env>/kubeconfig` — server endpoint
     is the LB floating IP (`:6443`), reachable from anywhere in
     `ingress_cidrs`.
   - SSH to a private node: use the ready-to-use command from the `bastion`
     output (`ssh -i env/OVH/<env>/.key.private ... -o ProxyCommand='ssh -W
     %h:%p ...'`). Nodes are never directly reachable.
5. **Operate** — `kubectl` against the LB endpoint; Ansible operates through
   the ProxyCommand in `ansible.cfg` (see `just play`).
6. **Replace a node** — `PROVIDER=OVH ENV=<env> just replace <name>` (bastion
   or non-bootstrap private node; OVH applies the full dependency graph). The
   first K3s/RKE2 controller is refused — etcd snapshot + distribution restore
   procedure only.
7. **Bastion recovery** — `just replace bastion`, then reconnect with the
   command from the fresh `bastion` output. If SSH is impossible, use OVH
   console/rescue with scoped credentials; never add a public NIC or LB
   TCP/22 as a backdoor.
8. **Destroy** — `just destroy` reverses the graph (LB → gateway/FIP → VMs →
   network).

Migration caveat: toggling `ssh_jump_enabled` on an existing cluster is a
disruptive rebuild (root disks and node public IPs replaced) — back up
etcd/workloads, schedule downtime, and save/review the full plan first.

---

## Replace & Destroy

- `just replace NAME`:
  - Azure/Libvirt: target-scoped replacement.
  - OVH: full-graph `-replace` so dependent networking (gateway/LB/FIP) is
    recreated coherently.
  - The first K3s/RKE2 controller is refused: automatic etcd datastore
    rejoin is not implemented; use a verified etcd snapshot + distribution
    restore procedure.
- `just destroy` reverses the graph: LB → gateway/FIP → VMs → network.
  OVH destroy-time cleanup handles floating-IP orphan lifecycle.
- Orphaned resources (LBs, FIPs, VLANs) from aborted applies are not
  removed by tofu; delete them via the provider API or `tofu import` where
  appropriate.

---

## Recovery

- **OVH bastion**: `PROVIDER=OVH ENV=<env> just replace bastion`; reconnect
  with the command from the `bastion` output.
- **Bastion unreachable**: OVH console/rescue with scoped OVH/OpenStack
  credentials; do not expose private nodes or LB TCP/22 as a backdoor.
- **First controller**: etcd snapshot + restore procedure (K3s or RKE2);
  automatic rejoin is not implemented.
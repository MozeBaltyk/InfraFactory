# InfraFactory Architecture

This document describes the system architecture and the rationale behind it.
It is the source of truth for architectural rules; implementation rules live in
`AGENTS.md` and `.local/AGENTS.md`.

## 1. Purpose

InfraFactory is a provider-agnostic Infrastructure-as-Code framework for
provisioning Kubernetes and VM environments across:

- Libvirt
- Azure
- OVH

A user describes an environment once. InfraFactory translates that description
into provider infrastructure, bootstraps the selected cluster implementation,
generates operational artifacts, and validates the resulting environment.

The primary design goal is:

> Provider-specific infrastructure below; provider-independent cluster behavior above.

---

## 2. Architectural Principles

### 2.1 One user entrypoint

Users interact with InfraFactory through the root `justfile`.

Typical workflow:

```text
just validate
just plan
just deploy
just check
just destroy
```

Provider-specific implementation details must not leak into the normal user
workflow.

### 2.2 One declarative environment definition

The user-facing source of truth is:

```text
env/<PROVIDER>/<environment>.tfvars
```

Users should not need to modify Terraform modules, templates, generated files,
or provider implementation code to create an environment.

### 2.3 Provider parity

Libvirt, Azure, and OVH implement the same logical contract.

Provider implementations may differ internally, but after infrastructure
creation they must produce the same normalized representation of a cluster.

```text
                ┌── Libvirt
Configuration ──┼── Azure   ──► Normalized cluster model
                └── OVH
```

Everything after normalization should be provider-independent whenever
practical.

### 2.4 Provider-specific behavior stays provider-specific

Examples:

```text
Azure
  └── NSG

OVH
  ├── vRack/private network
  ├── Load Balancer
  └── optional bastion

Libvirt
  ├── bridge/NAT
  └── local image cache
```

These concerns belong in their respective provider implementations.

---

## 3. System Layers

InfraFactory consists of six logical layers.

```text
Environment configuration
          │
          ▼
Provider infrastructure
          │
          ▼
Normalized node model
          │
          ▼
Bootstrap transport
          │
          ▼
Cluster implementation
          │
          ▼
Artifacts + validation
```

### 3.1 Orchestration

Location:

```text
justfile
providers/*/justfile
```

Responsibilities:

- select provider/environment
- invoke OpenTofu
- invoke validation
- invoke Ansible when required
- expose a consistent CLI

The `justfile` MUST remain an orchestration layer. Infrastructure decisions
MUST NOT be implemented primarily in Just recipes.

---

### 3.2 Configuration

Location:

```text
env/<PROVIDER>/<environment>.tfvars
```

Defines:

- cluster identity
- cluster implementation
- node topology
- CPU/memory/disk
- networking
- provider-specific options
- optional GitOps behavior

Example conceptual configuration:

```text
cluster
  type = talos

nodes
  controlplane = 3
  worker       = 3

network
  mode = private

provider
  ovh = {...}
```

---

## 4. Provider Infrastructure Layer

Location:

```text
providers/
├── libvirt/
├── azure/
└── ovh/
```

Provider modules are responsible for creating infrastructure only.

Examples:

- VMs
- disks
- networks
- security groups
- load balancers
- cloud-specific identities
- bastions where required

They MUST translate cloud resources into the normalized node model.

---

## 5. Normalized Node Model

The normalized node model is the boundary between cloud infrastructure and
cluster implementation.

Every provider MUST produce equivalent node objects.

Conceptually:

```hcl
nodes = {
  node01 = {
    name               = "node01"
    role               = "controlplane"

    private_ip         = "10.0.30.10"
    public_ip          = null

    operator_address   = "10.0.30.10"
    bootstrap_endpoint = "127.0.0.1:50000"

    cpu                = 4
    memory             = 8192
    disks              = []
  }
}
```

In the current implementation the normalized model is exposed through the
`cluster_nodes` output (`controller_ips`, `worker_ips`, `vm_ips`,
`public_ips`, `private_ips`, and a full `nodes` map of §5 node objects) plus
the shared node objects consumed by `platform/`.

Provider-specific resources MUST NOT be required by downstream cluster
modules when the normalized model can represent the required information.

---

## 6. Endpoint Model

Different addresses have different purposes. They MUST NOT be treated as
interchangeable.

### Node address

Identity/address of the actual machine.

Example:

```text
10.0.30.10
```

### Bootstrap endpoint

Address used by provisioning tooling before the cluster is operational.

Example (Talos, conceptually):

```text
127.0.0.1:50000
```

which may represent:

```text
localhost:50000
      │
      └── SSH tunnel ──► node01:50000
```

Bootstrap endpoints MUST be deterministic per node.

### Management endpoint

Stable endpoint used after the cluster exists.

Example:

```text
talos.example.com:50000
```

or:

```text
OVH-LB-IP:50000
```

### Kubernetes endpoint

Stable Kubernetes API endpoint.

Example:

```text
k8s.example.com:6443
```

---

## 7. Provisioning Lifecycle

Provisioning is divided into explicit phases.

### Phase 1 — Network

Create:

- networks
- subnets
- routing
- security groups
- load balancers

### Phase 2 — Compute

Create:

- control-plane nodes
- workers
- standalone VMs
- disks

### Phase 3 — Bootstrap transport

Establish whatever connectivity the provisioning system requires.

Examples:

```text
Libvirt → direct node connectivity

Azure → public/private endpoint depending on configuration

OVH → direct or SSH forwarding (jump) depending on network model
```

This phase exists to provide deterministic per-node connectivity.

### Phase 4 — Cluster bootstrap

Cluster-specific implementation executes.

```text
Talos
  ├── machine configuration
  ├── bootstrap etcd
  └── obtain kubeconfig

K3s
  └── cloud-init / Ansible

RKE2
  └── cloud-init / Ansible
```

### Phase 5 — Day-2 endpoints

Once the cluster is healthy, operational tools switch to stable management
endpoints.

Example:

```text
Talos bootstrap:

Terraform
   ↓
localhost tunnel
   ↓
node:50000


Talos day-2:

talosctl
   ↓
Load Balancer:50000
   ↓
control plane
```

Bootstrap endpoints MUST NOT leak into final user-facing configuration unless
intentionally required. (Illustrative example — actual Talos is libvirt-only
and connects directly to per-node endpoints; see `docs/networking.md`.)

### Phase 6 — Artifacts and validation

Generate:

```text
env/<PROVIDER>/<environment>/
├── hosts.ini
├── ansible.cfg
├── kubeconfig
├── talosconfig        (Talos mode, libvirt)
├── .key.private
└── .key.pub
```

Only applicable artifacts should be generated. OVH jump-mode connectivity is
embedded in `ansible.cfg` / output commands via a self-contained
`ProxyCommand` (see `docs/networking.md`); no `ssh_config` file is generated.

Generated artifacts MUST NOT be written into `providers/`.

---

## 8. Cluster Implementations

Cluster implementation should progressively move out of individual provider
directories.

Target architecture:

```text
providers/
  libvirt/
  azure/
  ovh/

platform/
  talos/
  cloud-init/      # renderer + per-type templates (default/k3s/rke2)
  artifacts/       # ssh-keys + ansible-artifacts
  inventory/
  ansible/
  validation/      # target: post-deploy checks shared across providers
```

Providers answer:

> What infrastructure exists and how can it be reached?

Cluster modules answer:

> How is Kubernetes installed and operated on those nodes?

Current state: shared modules live under
`platform/` (`ssh-keys`, `ansible-artifacts` under `platform/artifacts/`,
`cloudinit-renderer` under `platform/cloud-init/`, `talos-cluster` under
`platform/talos/`); shared cloud-init templates co-located with the renderer
under `platform/cloud-init/`; shared inventory template under
`platform/inventory/hosts.tpl`; shared playbooks under `platform/ansible/`.

---

## 9. Talos-Specific Model

Talos has an important distinction between bootstrap and day-2 connectivity.

During initial configuration:

```text
Terraform
   │
   ├──► node01:50000
   ├──► node02:50000
   ├──► node03:50000
   └──► node04:50000
```

Each node requires deterministic connectivity.

After bootstrap:

```text
talosctl
     │
     ▼
Load Balancer :50000
     │
     ▼
Control Plane
     │
     └──► target Talos node
```

Therefore:

```text
bootstrap_endpoint != management_endpoint
```

The generated user-facing `talosconfig` MUST contain the management endpoint,
not temporary bootstrap tunnels. (The Load Balancer diagram above is
illustrative of the endpoint distinction; current Talos deployments are
libvirt-only, without an LB.)

Note: Talos is currently implemented for libvirt only (`talos-cluster`
module); Azure and OVH deploy k3s/rke2.

---

## 10. Provider Contract

Every provider MUST expose equivalent logical outputs.

Required conceptual outputs:

```text
cluster_nodes
bootstrap_endpoints
management_endpoint
kubernetes_endpoint

inventory
kubeconfig
talosconfig
ssh_config
```

An output may be `null` when it does not apply.

Provider-specific consumers MUST NOT redefine the meaning of these fields.

Current state: `cluster_nodes` (including full §5 node objects under `nodes`),
`kubeconfig_command`, `bootstrap_endpoints`, `management_endpoint` and
`kubernetes_endpoint` exist on all three providers; `kube_api_load_balancer`
and `bastion` on OVH. `inventory`, `kubeconfig` and `talosconfig` are not
standalone outputs (rendered artifacts / commands instead); `ssh_config` is
intentionally not generated (self-contained `ProxyCommand` transport, see
`docs/networking.md`). The full conceptual contract is specified in
`docs/provider-contract.md`.

---

## 11. Validation

Provider parity MUST be tested rather than assumed.

Tests should verify invariants such as:

```text
✓ all providers produce normalized nodes
✓ generated artifacts remain under env/
✓ private-only nodes don't unexpectedly receive public IPs
✓ Talos bootstrap endpoints are deterministic
✓ Talos final talosconfig uses management_endpoint
✓ Kubernetes endpoint is stable
✓ provider outputs have equivalent semantics
```

Use OpenTofu tests for module/contract validation. Use live provider tests
only where cloud behavior itself needs validation.

Current state: shared-module contracts are tested through
`tests/contracts/` (`just test`); provider parity beyond that is validated
through `providers/README`'s documented test matrix and deploy-time checks
(`checks.tf` on OVH). Live provider test trees (`tests/{libvirt,azure,ovh}/`)
are target-shape.

---

## 12. Repository Direction

Target structure:

```text
InfraFactory/
├── env/
├── providers/
│   ├── libvirt/
│   ├── azure/
│   └── ovh/
│
├── platform/
│   ├── talos/
│   ├── cloud-init/        # renderer + per-type templates
│   ├── artifacts/         # ssh-keys + ansible-artifacts
│   ├── inventory/
│   ├── ansible/
│   └── validation/        # target: shared post-deploy checks
│
├── tests/
│   ├── contracts/
│   ├── libvirt/           # target: live provider tests
│   ├── azure/
│   └── ovh/
│
└── docs/
```

This is a target architecture, not a requirement for an immediate
repository-wide migration. Refactoring MUST be incremental.

---

## 13. Architectural Invariants

These rules should remain true as InfraFactory evolves:

1. Users configure environments through `env/`.
2. Provider-specific cloud behavior remains inside the provider layer.
3. Providers produce a normalized node model.
4. Cluster implementations consume normalized nodes rather than raw cloud
   resources whenever possible.
5. Bootstrap and management endpoints are separate concepts.
6. Generated artifacts live under `env/`.
7. Root `justfile` remains the user entrypoint.
8. Provider parity is validated automatically.
9. GitOps uses the same provider implementation and is not a second
   infrastructure implementation.
10. Refactoring must preserve working providers incrementally.

---

## References

- `docs/provider-contract.md` — canonical provider interface
- `docs/lifecycle.md` — provisioning phases
- `docs/networking.md` — address/endpoint terminology
- `docs/decisions/` — architecture decision records
- `providers/README` — per-provider capability details and test matrix
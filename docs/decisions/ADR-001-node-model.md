# ADR-001: Normalized Node Model

- Status: accepted
- Date: 2026-08-17
- Related: `docs/architecture.md`, `docs/provider-contract.md`

## Context

Each provider provisions VMs through different resources (libvirt domains,
Azure VM resources, OVH instances). Downstream cluster logic — cloud-init
rendering, inventory generation, Ansible transport, Talos orchestration —
needs a consistent view of the machines it operates on. Early on, this logic
reached into provider-specific resources and local maps, which duplicated
code and made every provider change cascade across all consumers.

## Decision

Introduce a normalized node model that every provider exposes:

- `controller_ips` / `worker_ips` / `vm_ips` (and `public_ips` /
  `private_ips` where applicable) in the `cluster_nodes` output.
- A per-VM object shape used by shared modules: name, role, private/public
  IP, sizing, extra disks, user-data toggle, cloud-init selection.

Shared consumers (`platform/`) depend only on this model,
never on raw provider resources. The canonical inventory template
(`platform/inventory/hosts.tpl`) is shared across providers.

## Consequences

### Positive

- Shared modules are provider-agnostic; a change affects one module + three
  provider call sites, not every consumer.
- Provider parity is testable by comparing normalized outputs.
- Inventory/Ansible/Talos logic is written once.

### Negative / Costs

- Each provider must map its native resources into the normalized shape.
- Provider-specific capabilities (per-role IP/MAC on libvirt, NSG on Azure,
  bastion on OVH) must be expressed as optional fields so the model stays
  symmetric.

### Trade-offs

- Normalization may lose provider-specific detail; that detail belongs to
  the provider directory, not downstream logic.
- A stricter typed model would reject more at plan time but is not worth the
  added coupling until the set of fields stabilizes.

## Alternatives Considered

- **Consumers reach into provider resources directly**: rejected — duplicates
  logic and couples shared code to cloud specifics.
- **One mega-module per provider**: rejected — violates modularity and makes
  cross-provider reuse impossible.
# ADR-003: Provider Parity

- Status: accepted
- Date: 2026-08-17
- Related: `docs/provider-contract.md`, `providers/README`, `AGENTS.md`

## Context

InfraFactory targets libvirt, Azure, and OVH. Without a parity rule, each
provider would drift toward its own variable schema, output shape, and
behavior — making the tool a collection of unrelated deployments rather than
a factory. Users must be able to move a cluster definition between providers
with minimal changes.

## Decision

All providers MUST implement the common capability baseline
(`docs/provider-contract.md`) with equivalent logical inputs and outputs.
Provider-specific capabilities may extend the baseline only when technically
required, and must be confined to the provider contract:

- **Azure**: NSG rules, Azure-native networking/security resources.
- **Libvirt**: per-role IP/MAC settings, NAT/bridge network modes, DHCP/static.
- **OVH**: dedicated bastion, load balancer + gateway/FIP lifecycle, private
  network/subnet.

Feature implementation follows priority order:

1. **libvirt** (local development, offline, fast feedback)
2. **azure** (primary real cloud target)
3. **ovh** (secondary)

When a provider lacks a capability, implement the closest equivalent or
document the limitation clearly. Provider changes must preserve or extend
the test matrix in `providers/README`.

## Consequences

### Positive

- One mental model for all clouds; consistent validation.
- Shared modules (ssh-keys, cloudinit-renderer, ansible-artifacts,
  talos-cluster) work identically across providers.
- Feature design can be iterated cheaply on libvirt before paying for cloud
  resources.

### Negative / Costs

- Provider-specific features require extra care to keep the baseline
  symmetric.
- Limitations must be tracked per provider (e.g. OVH extra/root disks are
  blocked, Azure has no static IP option).
- Every shared-contract change touches three providers plus docs/tests.

## Alternatives Considered

- **Best-effort parity, no contract**: rejected — drift makes the factory
  unusable.
- **Full parity including provider-specific features everywhere**: rejected —
  forces artificial features (e.g. IP/MAC lists on Azure) and blocks needed
  extensions.
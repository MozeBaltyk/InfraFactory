<p align="center">
  <img src="assets/InfraFactory.png" alt="Project Logo" width="180">
</p>

<p align="center">
  My InfraFactory for building cloud infrastructure, provider-agnostic and modular based on OpenTofu and Just.
</p>

---

## Overview

InfraFactory provides a **provider-agnostic, modular, and reproducible way** to provision infrastructure across different cloud platforms.

**Workflow:** OpenTofu → VM provisioning → cloud-init bootstrap → inventory generation → Ansible configuration

Infrastructure deployments are governed by the [InfraFactory Constitution](.specify/memory/constitution.md), which enforces modular design, provider symmetry, and consistent provisioning workflows across all cloud providers.

---

## Implementation Status

| Provider | Status |
|----------|--------|
| Libvirt | In progress (fixing issues) |
| OVH | Not started |
| Azure | Not started |
| DigitalOcean | Not started |

---

## Roadmap

### Phase 1: Foundation
- [x] TODO.md created
- [x] README.md expanded

### Phase 2: Provider Libvirt
- [x] Set up libvirt provider directory structure
- [x] Fix variables.tf (add missing vars)
- [x] Fix keys.tf
- [x] Fix main.tf (add cloud-init disk attachment)
- [x] Fix templates.tf (rename from .notready)
- [x] Fix output.tf (inventory path, remove sleep workaround)
- [ ] Test end-to-end

---

## Usage

Run `just` to see available commands.

```bash
just
Available recipes:
    env      # Print current configuration
    validate # Validate Opentofu scripts
    plan     # Plan on Provider specified in PROVIDER env variable (default: KVM)
    deploy   # Deploy on Provider specified in PROVIDER env variable (default: KVM)
    destroy  # Destroy on PProvider specified in PROVIDER env variable (default: KVM)
```

---

## Governance

This project is governed by the [InfraFactory Constitution](.specify/memory/constitution.md), which defines:

- **Core Principles**: Modular design, provider symmetry, consistent provisioning workflow, layout consistency, minimal provider differences
- **Development Priority**: Libvirt (dev) → OVH (production) → Azure → DigitalOcean
- **Development Discipline**: Incremental field-by-field implementation, focused commits, no system modifications
- **Architecture Standards**: Schema coverage policy, provider parity validation

See [AGENTS.md](AGENTS.md) for detailed technical guidance and [constitution.md](.specify/memory/constitution.md) for governance rules.

---

## Known Limitations

- None yet

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
    env     # Print current configuration
    plan    # Plan on Provider specified in PROVIDER env variable (default: KVM)
    deploy  # Deploy on Provider specified in PROVIDER env variable (default: KVM)
    destroy # Destroy on PProvider specified in PROVIDER env variable (default: KVM)
```

---

## Known Limitations

- None yet

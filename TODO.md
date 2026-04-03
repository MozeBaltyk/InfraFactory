# TODO

## Current Status
Azure provider is implemented following the Libvirt pattern. Top-level Just orchestration delegates to provider-local justfiles via `mod`. Current priority is repo hygiene and Azure end-to-end validation before OVH development.

---

## Tasks

### Phase 1: Foundation
- [X] Create TODO.md with project tasks
- [X] Expand README.md with roadmap and implementation status
- [X] Refactor Just orchestration to provider-local justfiles with `mod`
- [X] Enforce branch-only workflow for AI-assisted development
- [X] Align README.md, TODO.md, and AGENTS.md with current implementation paths and priority order
- [X] Fix top-level Ansible play recipe path

### Phase 2: Provider Libvirt (Priority 1)
- [X] Set up libvirt provider directory structure
- [X] Implement variables.tf for libvirt
- [X] Implement keys.tf for libvirt
- [X] Implement main.tf for libvirt (VM provisioning)
- [X] Implement templates.tf for libvirt (cloud-init)
- [X] Implement outputs.tf for libvirt (inventory generation)
- [X] Test libvirt provider end-to-end

### Phase 3: Provider Azure (Priority 2)
- [X] Set up azure provider directory structure
- [X] Implement variables.tf for azure
- [X] Implement keys.tf for azure
- [X] Implement main.tf for azure
- [X] Implement templates.tf for azure
- [X] Implement outputs.tf for azure
- [ ] Test azure provider end-to-end

### Phase 4: Provider OVH (Priority 3)
- [ ] Set up ovh provider directory structure
- [ ] Implement variables.tf for ovh
- [ ] Implement keys.tf for ovh
- [ ] Implement main.tf for ovh
- [ ] Implement templates.tf for ovh
- [ ] Implement outputs.tf for ovh
- [ ] Test ovh provider end-to-end

### Phase 5: Ansible Integration
- [ ] Create ansible playbooks for cluster setup
- [ ] Test ansible integration with all providers

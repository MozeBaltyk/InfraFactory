# TODO

## Current Status
Libvirt provider fully implemented and tested locally on Ubuntu. Ready to proceed to OVH provider.

---

## Tasks

### Phase 1: Foundation
- [X] Create TODO.md with project tasks
- [X] Expand README.md with roadmap and implementation status

### Phase 2: Provider Libvirt (Priority 1)
- [X] Set up libvirt provider directory structure
- [X] Implement variables.tf for libvirt
- [X] Implement keys.tf for libvirt
- [X] Implement main.tf for libvirt (VM provisioning)
- [X] Implement templates.tf for libvirt (cloud-init)
- [X] Implement outputs.tf for libvirt (inventory generation)
- [X] Test libvirt provider end-to-end

### Phase 3: Provider Azure (Priority 2)
- [ ] Set up azure provider directory structure
- [ ] Implement variables.tf for azure
- [ ] Implement keys.tf for azure
- [ ] Implement main.tf for azure
- [ ] Implement templates.tf for azure
- [ ] Implement outputs.tf for azure
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

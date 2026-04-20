# TODO

## Current Status
Azure provider is implemented following the Libvirt pattern.

OVH now includes:
- public-IP-based operator access
- shared cloud-init bootstrap
- generated SSH keys, inventory, and kubeconfig
- optional private networking via `network.cidr`
- deterministic private IP assignment
- separate masters and workers
- multi-master clusters when `network.cidr` is set
- kube-api load-balancer exposure
- an optional exact-match floating-IP cleanup helper for destroy leftovers

Current OVH caveats:
- inventory remains public-IP based even when private networking exists
- private networking and kube-api load-balancer creation are currently coupled
- some multi-node readiness scenarios can still be inconsistent
- custom root disk sizing and extra disks are not supported yet
- cleanup of other implicit public IP leftovers still depends on OVH/provider behavior

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
- [X] Refactor libvirt VM domains to use unified `local.all_vms_map` resource loops
- [X] Test libvirt provider end-to-end

### Phase 3: Provider Azure (Priority 2)
- [X] Set up azure provider directory structure
- [X] Implement variables.tf for azure
- [X] Implement keys.tf for azure
- [X] Implement main.tf for azure
- [X] Implement templates.tf for azure
- [X] Implement outputs.tf for azure
- [X] Introduce `public_kube_api_endpoint` abstraction for Azure kubeconfig/output generation
- [ ] Test azure provider end-to-end

### Phase 4: Provider OVH (Priority 3)
- [X] Set up ovh provider directory structure
- [X] Implement variables.tf for ovh
- [X] Implement keys.tf for ovh
- [X] Implement main.tf for ovh
- [X] Implement templates.tf for ovh
- [X] Implement outputs.tf for ovh
- [X] Test ovh provider end-to-end
- [X] Add optional exact-match orphaned floating-IP cleanup helper for OVH destroy flows
- [ ] Investigate cleanup of OVH gateway or other implicit public IP leftovers not covered by the exact-match floating-IP helper

### Phase 5: Ansible Integration
- [ ] Create ansible playbooks for cluster setup
- [ ] Test ansible integration with all providers

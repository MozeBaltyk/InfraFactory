# TODO

## Current Status
Azure provider is implemented following the Libvirt pattern.
GitOps now includes `just` recipes for Flux/tofu-controller Terraform stack status, watch, logs, runner, lock, and event inspection from the `gitops/` folder.
RKE2 Cilium cloud-init supports nested Cilium options, including configurable operator replicas for kube-proxy replacement mode.
RKE2 Cilium L2 announcements are consistently modeled across Libvirt, Azure, and OVH providers.

OVH now includes:
- public-IP-based operator access
- shared cloud-init bootstrap
- generated SSH keys, inventory, and kubeconfig
- optional private networking via `network.private_cidr`
- deterministic private IP assignment
- separate masters and workers
- multi-master clusters when `network.private_cidr` is set
- kube-api load-balancer exposure
- an exact-match floating-IP cleanup helper and subnet port drain for destroy leftovers
- OVH private NIC netplan override with explicit empty routes, strict permissions, and route cleanup without overriding public cloud networking
- Ansible-based cloud-init readiness check
- Ansible-based TLS SAN reconciliation (adds public IP to kube-apiserver cert)
- Ansible-based kubeconfig fetch with public IP endpoint
- standalone extra VMs via `infra.vms`, including VM-only default cloud-init deployments
- OVH extra VMs receive common default cloud-init plus the OVH private-netplan overlay
- optional master SSH jump listener on the kube-api load balancer, targeting only the first master
- explicit `just` recipes for planning and applying targeted OVH VM replacement

Libvirt has been realigned with the recent OVH baseline for standalone `infra.vms`, per-role `user_data_enabled`, shared default cloud-init on standalone VMs, inventory VM groups, and normalized controller/worker/VM IP outputs.

Azure has been realigned with the recent OVH/Libvirt baseline for standalone `infra.vms`, per-role `user_data_enabled`, shared default cloud-init on standalone VMs, inventory VM groups, normalized public/private IP outputs, and Ansible task gating.

---

## Tasks

### Phase 1: Foundation
- [X] Create TODO.md with project tasks
- [X] Expand README.md with roadmap and implementation status
- [X] Refactor Just orchestration to provider-local justfiles with `mod`
- [X] Enforce branch-only workflow for AI-assisted development
- [X] Align README.md, TODO.md, and AGENTS.md with current implementation paths and priority order
- [X] Fix top-level Ansible play recipe path
- [X] Add GitOps-local monitoring recipes for Flux/tofu-controller Terraform stacks

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
- [X] Align Azure provider with standalone VM and normalized output baseline
- [ ] Test azure provider end-to-end

### Phase 4: Provider OVH (Priority 3)
- [X] Set up ovh provider directory structure
- [X] Implement variables.tf for ovh
- [X] Implement keys.tf for ovh
- [X] Implement main.tf for ovh
- [X] Implement templates.tf for ovh
- [X] Implement outputs.tf for ovh
- [X] Test ovh provider end-to-end
- [X] Add explicit plan/apply recipes for targeted OVH VM replacement

### Phase 5: Ansible Integration
- [X] Create shared ansible playbook: `check_cloudinit.yml` — wait for cloud-init to finish on all nodes
- [X] Create shared ansible playbook: `fetch_kubeconfig.yml` — fetch kubeconfig from first master, rewrite server endpoint
- [X] Create shared ansible playbook: `reconciliate_tls.yml` — add public IP to kube-apiserver TLS SAN, restart service
- [X] Wire ansible integration into OVH provider (`ansible.tf`) — full deploy flow with check → reconcile → fetch
- [X] Wire ansible integration into Azure provider
- [X] Wire ansible integration into Libvirt provider
- [ ] Create ansible playbooks for additional cluster setup / post-provisioning

### Phase 6: Cluster Bootstrap Options
- [X] Add nested RKE2 Cilium options with configurable operator replicas for kube-proxy replacement mode
- [X] Align RKE2 Cilium L2 announcement inputs across Libvirt, Azure, and OVH

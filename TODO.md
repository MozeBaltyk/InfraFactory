# TODO

## Current Status
Azure provider is implemented following the Libvirt pattern.
GitOps now includes `just` recipes for Flux/tofu-controller Terraform stack status, watch, logs, runner, lock, and event inspection from the `gitops/` folder.

OVH now includes:
- public-IP-based operator access
- shared cloud-init bootstrap
- generated SSH keys, inventory, and kubeconfig
- optional private networking via `network.private_cidr`
- deterministic private IP assignment
- separate masters and workers
- multi-master clusters when `network.private_cidr` is set
- kube-api load-balancer exposure
- an optional exact-match floating-IP cleanup helper for destroy leftovers
- Ansible-based cloud-init readiness check
- Ansible-based TLS SAN reconciliation (adds public IP to kube-apiserver cert)
- Ansible-based kubeconfig fetch with public IP endpoint

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
- [ ] Test azure provider end-to-end

### Phase 4: Provider OVH (Priority 3)
- [X] Set up ovh provider directory structure
- [X] Implement variables.tf for ovh
- [X] Implement keys.tf for ovh
- [X] Implement main.tf for ovh
- [X] Implement templates.tf for ovh
- [X] Implement outputs.tf for ovh
- [X] Test ovh provider end-to-end

### Phase 5: Ansible Integration
- [X] Create shared ansible playbook: `check_cloudinit.yml` — wait for cloud-init to finish on all nodes
- [X] Create shared ansible playbook: `fetch_kubeconfig.yml` — fetch kubeconfig from first master, rewrite server endpoint
- [X] Create shared ansible playbook: `reconciliate_tls.yml` — add public IP to kube-apiserver TLS SAN, restart service
- [X] Wire ansible integration into OVH provider (`ansible.tf`) — full deploy flow with check → reconcile → fetch
- [X] Wire ansible integration into Azure provider
- [X] Wire ansible integration into Libvirt provider
- [ ] Create ansible playbooks for additional cluster setup / post-provisioning

### Phase 6: Provider module extraction (drift reduction)
- [X] Evaluate candidate shared modules (keys/ansible/cloud-init/talos) across libvirt/azure/ovh
- [X] M1: extract `providers/shared/modules/ssh-keys`, migrate libvirt/azure/ovh, `tofu state mv` live libvirt cluster
- [ ] M1: full fresh-deploy validation (destroy + apply) on libvirt
- [ ] M3: extract cloudinit-renderer module (k3s/rke2/ansible/extra_packages var surface)
- [ ] M2: extract ansible-artifacts module (ansible.cfg + hosts.ini + fetch/reconcile flow)
- [ ] M4: extract talos module (talos.tf)

### Eval: Talos on libvirt (branch `eval/talos-deployment`)
- [X] Deploy 1 control-plane + 1 worker, k8s v1.36.0 / Talos v1.13.7 (live cluster)
- [X] Talos provider features: factory image URL, cluster health gate, talosconfig artifact
- [ ] Decide: promote Talos as documented provider mode (k3s/rke2/talos) or close the eval branch

# Plan — summary

Backlog index. Detail lives in per-phase files (bastion split) and the
sections below (everything else). Decisions in `../decisions/`.

## OVH bastion split (`ovh-refactor`)

One mutualized standalone bastion serving many clusters. Full story in
`../decisions/2026-09-18-ovh-bastion-split.md`.

| Phase | File | Status |
|---|---|---|
| P0 shared IPAM | `phase-00-ipam.md` | done (`eb10003`) |
| P1 bastion skeleton | `phase-01-skeleton.md` | done (`ef59c0e`) |
| P2 hot-attach multi-NIC | `phase-02-hotattach.md` | done on branch (`bf06ed5`), live proof deferred to P5 |
| P3 cluster decoupling | `phase-03-decoupling.md` | offline done (validate all providers pass; authenticated plan proof pending) |
| P4 day-2 + recipes | `phase-04-day2.md` | offline done (role + `converge` recipe, G4 green; live proof in P5) |
| P5 live validation | `phase-05-live.md` | blocked on explicit approval |
| P6 close-out | `phase-06-closeout.md` | pending |

## Remaining backlog (non-split, OVH focus)

- [ ] First-controller etcd backup/restore recovery (`just replace` stays blocked meanwhile)
- [ ] Additional Ansible post-provisioning playbooks
- [ ] OVH storage per-role attach by key (`nfs`/`object_storage`/`block_storage`)
- [ ] OVH `just replace` recipes (full-graph VM replacement; first-controller stays blocked)
- [ ] OVH: merge `vms` + `private_cluster` into one resource over `all_vms_map` (no behavior change)
- [ ] OVH: split `clusters/variables.tf` (vars only, locals to `topology.tf`)
- [ ] Talos support status: documented provider mode or experimental (module + libvirt wiring exist, no eval branch anymore)
- [ ] Bastion shutdown = stop/shelve or delete?
- [ ] VPN to replace the bastion later?
- [ ] Ingress path: Octavia NodePorts vs MetalLB/Cilium-L2 VIP? TLS at LB or controller?
- [ ] Golden images (bake level, CI Packer, regions)?

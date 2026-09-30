# Plan — summary

Backlog index. Active workstreams use the per-phase files indexed below;
smaller backlog items remain in this file. Decisions live in `../decisions/`.

## OVH bastion split (`ovh-refactor`)

One mutualized standalone bastion serving many clusters. Full story in
`../decisions/ADR-01-ovh-bastion-split.md`. Follow-up consolidation
on the branch: jump-only Kubernetes (`ADR-02`: guards + deleted public
branches) and the
single-resource merge (`vms` + `private_cluster`, state-mv note in
`moved.tf`) — both offline-validated on the branch.

| Phase | File | Status |
|---|---|---|
| P0 shared IPAM | `phase-00-ipam.md` | offline done (`eb10003`); authenticated no-op evidence not retained |
| P1 bastion skeleton | `phase-01-skeleton.md` | offline done (`ef59c0e`) |
| P2 hot-attach multi-NIC | `phase-02-hotattach.md` | offline done (`bf06ed5`); live acceptance in P5 |
| P3 cluster decoupling | `phase-03-decoupling.md` | offline done; authenticated migration proof remains in P5 |
| P4 day-2 + recipes | `phase-04-day2.md` | offline done; partial live observation, acceptance in P5 |
| P5 live validation | `phase-05-live.md` | partial observations; G5/G6 require explicit approval |
| P6 close-out | `phase-06-closeout.md` | partial offline docs; exit pending P5 |

## OVH Talos (`talos-ovh`)

Additive workstream for a new Talos mode on disposable OVH infrastructure.
Existing `default`, K3s, and RKE2 installations are non-regression references
only, never test subjects; no state surgery or paid operation is part of the
offline phases.

| Phase | File | Status |
|---|---|---|
| TO0 contract + decisions | `phase-07-contract-decisions.md` | pending |
| TO1 offline contracts | `phase-08-offline-contracts.md` | pending |
| TO2 image + network boot | `phase-09-image-network.md` | pending |
| TO3 bootstrap + management | `phase-10-bootstrap-management.md` | pending |
| TO4 authenticated no-apply regression | `phase-11-plan-regression.md` | pending |
| TO5 paid scratch deployment | `phase-12-experimental-live.md` | blocked on explicit approval |
| TO6 lifecycle/security proof | `phase-13-lifecycle-proof.md` | blocked on TO-G5 and explicit approval |
| TO7 documentation closeout | `phase-14-closeout.md` | pending |

## Remaining backlog (non-split, OVH focus)

- [ ] First-controller etcd backup/restore recovery (`just replace` refuses it meanwhile)
- [ ] OVH block-storage create/attach lifecycle (NFS and object-storage
      attachment by key are implemented)
- [ ] First-boot DNS race: move base packages out of `packages:` into `runcmd`
      (or set subnet `dns_nameservers`) so cloud-init's early package install
      runs after DNS converges — see `../troubleshooting/ovh-cloud-init-dns-race.md`
- [ ] `converge` recipe: accept a repo-root-relative KEY path (currently resolves
      relative to `providers/ovh/bastion/`, so operators must pass an absolute path)

## Parking lot (not active backlog)

- Additional Ansible post-provisioning playbooks (define a concrete use case first)
- Bastion stop/shelve lifecycle instead of deletion
- VPN as a possible future bastion replacement
- Golden-image baking/CI/region strategy

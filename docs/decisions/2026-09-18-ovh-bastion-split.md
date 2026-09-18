# 2026-09-18 — OVH bastion split (standalone bastion + cluster stacks)

Distilled from `docs/refactoring/01-bastion-split-analysis.md` (removed after
dispatch). Status: Phases 0–2 implemented on branch `ovh-refactor`; Phases
3–6 tracked in `docs/plan/`.

## Context

The OVH bastion was embedded in the cluster workspace (`bastion.tf`, gated on
`lb_ssh_jump_enabled`) with six couplings: bastion IP from cluster counts,
`PermitOpen` enumerating node IPs, SG `remote_group_id` reference,
gateway/LB `depends_on` (bastion replacement churned gateway + LB), Ansible
`proxy_jump` on the embedded IP, and VM replacement on any cloud-init change.

## Decisions

1. **One mutualized bastion, own deployment.** `providers/ovh/bastion/` as an
   independent root module with its own tfvars; serves many clusters by
   attaching to many private networks.
2. **Per-cluster SSH keys, terraform-generated** into
   `env/OVH/<cluster>/.key.{private,pub}`. Rejected: one bastion-generated
   keypair for all clusters (single skeleton key, bastion holding the one
   private key that opens everything).
3. **Only public keys flow cluster → bastion.** The bastion forwards bytes
   (`AllowTcpForwarding local`, `ip_forward=0`); the laptop holds the private
   key end-to-end. No shared state, no remote-state backend.
4. **Bastion-first bootstrap.** Born standalone (public NIC + operator admin
   key only, `clusters = {}`); clusters attach iteratively. Hence a
   permanent `admin_public_keys` seed is mandatory, and the empty-cluster
   `PermitOpen` restriction is omitted (empty allowlist would lock out
   forwarding).
5. **Reserved bastion IP by convention.** Last usable host of each cluster
   CIDR, computed independently by both stacks via `providers/shared/modules/ipam`
   — no shared state. Node allocation must never reach it (guarded).
6. **Hot-attach, never replace.** Private NICs are managed ports +
   `interface_attach`; day-2 key/netplan/`PermitOpen` convergence is
   Ansible-owned with `ignore_changes = [user_data]` and no replace trigger.
7. **Split is OVH-specific.** libvirt/Azure keep the embedded model; one line
   in `providers/README` + test matrix.

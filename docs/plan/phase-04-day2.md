# P4 — Day-2 convergence + workflow recipes — offline implementation done

New clusters (pubkey, `PermitOpen` entries, NICs) must converge via Ansible,
never via replacement.

Done: `providers/ovh/bastion/justfile` (`validate/plan/deploy`,
`destroy-vm` for VM-only teardown preserving ports/IPs, `destroy-all`),
`BASTION_ENV` decoupled from cluster workspaces, explicit `bastion-*`
recipes on the ovh router.

Done (offline): Ansible `bastion_converge` role (`ansible/roles/`) —
merge admin + cluster pubkeys into `authorized_keys`, write per-NIC
netplan + `netplan apply` + verify-service re-run, update `PermitOpen`
with `sshd -T` effective-policy verify + `systemctl reload ssh` +
re-verify (pattern: the former `infrafactory-verify-bastion-sshd`).
Wired via `providers/shared/ansible/converge_bastion.yml`, a `converge`
output on the bastion stack, and `just ovh::bastion::converge KEY`.
Documented bootstrap order (corrected by a partial live observation on
2026-09-18: converge must precede the cluster's Ansible phase):
bastion `apply` (empty) → `ENV=<env> just ovh::bootstrap` →
bastion `apply` with the entry → bastion `converge` (admin key; the
attach is state-only, the guest still has birth-time keys) → cluster
full `apply`.

Gate G4 (offline): recipe syntax, role `--syntax-check`, `validate` both
root modules are green. Offline work is closed; end-to-end live acceptance is
deferred to P5 and is not implied by the observed fail-closed SSH ordering.

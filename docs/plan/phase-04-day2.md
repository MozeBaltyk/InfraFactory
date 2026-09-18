# P4 — Day-2 convergence + workflow recipes — partial

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
Gate G4 green (playbook `--syntax-check`, recipe parses, `validate` both
root modules). Live proof deferred to P5.

Pending: nothing offline. Documented bootstrap order:
bastion `apply` (empty) → cluster keys + network via targeted apply →
bastion `apply` with the entry → cluster full `apply`.

Gate G4 (offline): recipe syntax, role `--syntax-check`, `validate` both
root modules. No cloud contact.

# P4 — Day-2 convergence + workflow recipes — partial

New clusters (pubkey, `PermitOpen` entries, NICs) must converge via Ansible,
never via replacement.

Done: `providers/ovh/bastion/justfile` (`validate/plan/deploy`,
`destroy-vm` for VM-only teardown preserving ports/IPs, `destroy-all`),
`BASTION_ENV` decoupled from cluster workspaces, explicit `bastion-*`
recipes on the ovh router.

Pending: Ansible converge role for the bastion — merge cluster pubkeys into
`authorized_keys`, write per-NIC netplan + `netplan apply`, update
`PermitOpen` with `sshd -T` verify + `systemctl reload ssh` (pattern: the
former `infrafactory-verify-bastion-sshd`). Documented bootstrap order:
bastion `apply` (empty) → cluster keys + network via targeted apply →
bastion `apply` with the entry → cluster full `apply`.

Gate G4 (offline): recipe syntax, role `--syntax-check`, `validate` both
root modules. No cloud contact.

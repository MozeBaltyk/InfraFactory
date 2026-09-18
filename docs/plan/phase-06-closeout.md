# P6 — Docs + parity close-out — pending (two items done early, see below)

After P5 is green:

- `providers/README`: OVH split as provider-specific extension + updated
  test matrix; slim the baseline/matrix sections to link `docs/specs/`
  (normative home) instead of duplicating them. (OVH rows already
  realigned jump-only on the branch; matrix + slimming remain.)
- `env/OVH/tfvars.bastion.example`: final reference with a 2-cluster example.
- `docs/architectures/ovh/03-network.md`: embedded-bastion sections
  already realigned jump-only on the branch (standalone ownership,
  single-resource note, gateway-race open question); re-verify against
  P5 outcomes.
- `docs/procedures/ovh-bastion.md`: already drafted (two states/workspaces,
  `var.bastion` wiring, birth/attach order, multi-cluster constraints,
  embedded→standalone migration); verify against P5 outcomes and fix drift.
- `docs/specs/`: verify all four files against P5 outcomes (bastion-split
  gates, OVH deltas, matrix rows actually proven) and fix drift; new
  divergences get a dated `decisions/` record per the contract.
- `README.md` roadmap checkbox (only file outside the feature scope touched).
- Retire/annotate the split decision record if outcomes diverged from it.

Gate G6-exit: `git status` shows only intended files; `validate` green in
`providers/ovh` + `providers/ovh/bastion`; no secrets committed (`.key.*`,
`.openrc`, real tfvars stay untracked — verify with `git status --short`).

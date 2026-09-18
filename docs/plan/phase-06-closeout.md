# P6 — Docs + parity close-out — pending

After P5 is green:

- `providers/README`: OVH split as provider-specific extension + updated
  test matrix.
- `env/OVH/tfvars.bastion.example`: final reference with a 2-cluster example.
- `docs/architectures/ovh/03-network.md`: rewrite the embedded-bastion
  sections (bastion VM/SG/ports/probe in `clusters/`) for the standalone
  model; keep the incident history, mark pre-split entries as such.
- `docs/procedures/ovh-bastion.md`: already drafted (two states/workspaces,
  `var.bastion` wiring, birth/attach order, multi-cluster constraints,
  embedded→standalone migration); verify against P5 outcomes and fix drift.
- `README.md` roadmap checkbox (only file outside the feature scope touched).
- Retire/annotate the split decision record if outcomes diverged from it.

Gate G6-exit: `git status` shows only intended files; `validate` green in
`providers/ovh` + `providers/ovh/bastion`; no secrets committed (`.key.*`,
`.openrc`, real tfvars stay untracked — verify with `git status --short`).

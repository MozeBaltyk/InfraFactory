# P6 — Docs + parity close-out — pending

After P5 is green:

- `providers/README`: OVH split as provider-specific extension + updated
  test matrix.
- `env/OVH/tfvars.bastion.example`: final reference with a 2-cluster example.
- `README.md` roadmap checkbox (only file outside the feature scope touched).
- Retire/annotate the split decision record if outcomes diverged from it.

Gate G6-exit: `git status` shows only intended files; `validate` green in
`providers/ovh` + `providers/ovh/bastion`; no secrets committed (`.key.*`,
`.openrc`, real tfvars stay untracked — verify with `git status --short`).

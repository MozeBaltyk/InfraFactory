# P6 — Docs + parity close-out — partial offline; exit pending P5

After P5 is green:

- [ ] `providers/README`: re-verify OVH extension and rows after P5, update
  evidence, and slim duplicated baseline/matrix content in favor of normative
  `docs/specs/` links.
- [ ] `env/OVH/<project>/bastion/tfvars.example`: final reference with a 2-cluster
  example.
- [ ] `docs/architectures/ovh/03-network.md`: current implementation is
  realigned jump-only; re-verify it against P5 outcomes.
- [x] `docs/procedures/ovh-bastion.md`: drafted with two states/workspaces,
  `var.bastion` wiring, birth/attach order, multi-cluster constraints,
  and embedded→standalone migration.
- [ ] Verify the procedure against P5 outcomes and fix drift.
- [ ] `docs/specs/`: drafted/realigned for the standalone jump-only design;
  verify all five spec files against P5 outcomes (bastion-split
  gates, OVH deltas, matrix rows actually proven) and fix drift; new
  divergences get a numbered ADR in `decisions/` per the contract.
- [ ] `README.md` roadmap checkbox (only file outside the feature scope touched).
- [ ] Retire/annotate the split decision record if outcomes diverged from it.

Gate G6-exit: `git status` shows only intended files; `validate` green in
`providers/ovh` + `providers/ovh/bastion`; no secrets committed (`.key.*`,
`.openrc`, real tfvars stay untracked — verify with `git status --short`).

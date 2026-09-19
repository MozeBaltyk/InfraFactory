# TO7 — Documentation and support closeout — pending

## Goal

Align the repository contract, operator guidance, capability matrix, and
support label with evidence from TO5/TO6.

## Scope

- Update `env/OVH/tfvars.example`, `README.md`, `providers/README`, OVH specs,
  architecture, procedures, troubleshooting, and dated decisions without
  duplicating normative content.
- Record exact supported Talos/OVH version, image ownership, firmware, network
  bootstrap, install disk, transport, exposure, topology, recovery limits, and
  artifact paths.
- Add matrix rows for offline contracts, single-control-plane experimental
  proof, and HA/lifecycle proof. Label only evidence that passed: experimental
  after TO-G5, proven only after TO-G6.
- Document operator validation and rollback through root `just` recipes;
  classify plan/read-only, apply/destroy/disruptive, and disk/recovery actions
  appropriately. Require explicit approval for paid or destructive steps.
- Remove temporary work logs, keep secrets/tfvars/plans untracked, and replace
  this workstream's status in `summary.md` with the final evidence boundary.

## Gate TO-G7 — go/no-go

**Go:** links resolve, all provider validations and contract tests pass,
`git status --short` contains only intended source/docs and no secrets, and the
published support claim equals TO5/TO6 evidence. **No-go:** leave the workstream
open and the support label at its last proven level; do not close by assertion.

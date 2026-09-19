# TO1 — Offline contracts and failing tests — pending

## Goal

Make isolation and endpoint semantics executable before provider wiring.

## Scope

- Add OpenTofu contract tests for OVH Talos under `tests/`, with fixtures that
  require no credentials, refresh, network lookup, or paid resource.
- Cover: valid Talos/OS pairing; invalid mixed modes; no standalone VMs or
  cloud-init-only storage; private-only Talos nodes; deterministic distinct
  bootstrap endpoints; private `node_address`; stable management and
  Kubernetes endpoints; no SSH/token/Ansible artifacts; final `talosconfig`
  excluding bootstrap endpoints.
- Add non-regression cases for `default`, K3s, and RKE2 showing unchanged
  normalized topology and mode-specific branches.
- If tests need a new command, expose one thin `just` recipe; keep logic in
  OpenTofu/tests. Continue to use `PROVIDER=<AZ|KVM|OVH> just validate` for the
  existing provider validation flow.
- Capture the expected pre-implementation Talos failures so later phases turn
  them green without weakening assertions.

## Gate TO-G1 — go/no-go

**Go:** test fixtures initialize offline, legacy cases and all three provider
validations pass, and Talos tests fail only at named unimplemented boundaries.
**No-go:** tests require cloud credentials, inspect local state, or permit a
legacy branch to change. Fix the harness; do not begin OVH implementation.

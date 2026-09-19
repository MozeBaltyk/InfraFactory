# TO4 — Authenticated no-apply plan regression — pending

## Goal

Prove the implementation is isolated before any paid scratch deployment.

## Scope

With scoped credentials, run **plan only** through existing recipes; do not
apply, replace, import, move state, or target existing resources.

1. Inventory every currently deployed OVH workspace, then record baseline and
   candidate `PROVIDER=OVH ENV=<env> just plan` results for each one. Existing
   installations are evidence sources only: no configuration edits and no
   apply. Require zero resource changes in every workspace; explain
   provider/read-only refresh noise rather than accepting it. A sampled subset
   is not sufficient to pass this gate.
2. Run `PROVIDER=OVH ENV=<new-scratch-name> just plan` against a new Talos
   tfvars file and empty workspace. Require only additive Talos/network/LB
   resources, private-only nodes, no SSH/cloud-init/Ansible path, explicit
   image and disk, deterministic bootstrap endpoints, and stable 50000/6443
   endpoints.
3. Re-run `PROVIDER=KVM just validate` and `PROVIDER=AZ just validate`, TO1
   tests, and OVH validation.
4. Review the plan for credentials, private keys, machine secrets, broad CIDRs,
   unexpected replacements, and image deletion ownership. Keep plans and
   generated sensitive artifacts uncommitted.

Rollback before apply is code/config reversion only. Existing state must remain
unchanged throughout.

## Gate TO-G4 — go/no-go

**Go:** every existing workspace plan is no-op and the new empty scratch plan
matches the Talos-only graph. **No-go:** any existing change, replacement,
state operation, secret disclosure, or unexplained drift. Stop and restore
offline isolation; no paid command is authorized by this gate.

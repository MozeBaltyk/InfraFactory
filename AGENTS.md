# InfraFactory — AI Assistant Guide

## Read First

Before touching code, read:

- `docs/architecture.md` — layers, endpoint model, invariants
- `docs/provider-contract.md` — canonical provider interface
- `docs/lifecycle.md` — provisioning phases
- `docs/networking.md` — endpoint terminology, SSH transport
- `docs/decisions/` — accepted ADRs
- `providers/README` — per-provider capabilities + test matrix
- `TODO.md` — work backlog (task source of truth)
- `README.md` — user workflow

## Branch Safety

- NEVER work directly on `main`. Verify the branch before any change.
- If on `main`, stop and ask to create/switch to a feature branch first.
- Preserve dirty work on its own branch or stash before unrelated changes.
- All implementation, fixes, and documentation updates must happen on a
  separate branch.

## Working Rules

1. Work only inside the repository source directories.
2. Do not introduce new project structure without approval.
3. Do not create new `.md` files without explicit authorization.
4. NEVER install software or modify the system (no sudo, no package
   managers, no service restarts).
5. Preserve modular design; avoid provider-specific hacks.
6. Keep provider implementations consistent with `docs/provider-contract.md`.
7. Use `just` recipes for execution flows when available.
8. Keep `env/<PROVIDER>/tfvars.example` in sync with provider changes.
9. Update TODO.md as you complete tasks.
10. Prefer simplicity over clever abstractions.

## Development Workflow

Work incrementally: ONE field/feature → test → commit → repeat.

- Small focused commit messages (`feat: add title field`).
- No promotional text or "Generated with" messages.
- `Resolves: #xxx` for issues.
- Never batch multiple complex features in one iteration.

## Provider Documentation

- Libvirt: https://search.opentofu.org/provider/dmacvicar/libvirt/latest
- Azure: https://search.opentofu.org/provider/hashicorp/azurerm/latest
- OVH: https://search.opentofu.org/provider/ovh/ovh/latest

## Agent Contract

Operational agent rules (dependency direction, parity, endpoint semantics,
artifact rules): `.local/AGENTS.md`
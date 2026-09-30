# Context for AI Assistants

## Branch Safety Rule

**NEVER work directly on `main`.**

- Before making any change, verify the current git branch.
- If the current branch is `main`, stop and ask to create or switch to a dedicated feature branch first.
- If the working tree is dirty, preserve that work on its own branch or stash before starting unrelated changes.
- All implementation, fixes, and documentation updates must happen on a separate branch.

## Rules

The repository contract lives in `docs/00-repo-contract.md`. Read it before
making architectural, provider, or workflow changes and obey it.

Two rules always apply, no exceptions:

1. **Use `just` recipes** for execution flows (tests, validation, checks,
   deploy/destroy verification) whenever a matching recipe exists — never call
   the underlying tools directly.
2. **Never modify the system.** No sudo, no package installs, no service
   restarts. Work only inside the repository source directories. If a
   dependency is missing, inform the user.

## Where things live

- User workflow, status, roadmap, limits: `README.md`
- Work backlog: `docs/plan/summary.md`
- Provider test matrix and capabilities: `providers/README`
- Architecture and decisions: `docs/` (see `docs/00-repo-contract.md` for the map)

<!--
Sync Impact Report
- Version change: 1.0.0 -> 1.0.1
- Modified principles:
	- III. Provisioning Workflow (NON-NEGOTIABLE) -> III. Provisioning Workflow (NON-NEGOTIABLE)
	- IV. Consistent Provider Layout -> IV. Consistent Provider Layout
- Added sections: None
- Removed sections: None
- Templates requiring updates:
	- ✅ updated: .specify/templates/plan-template.md
	- ✅ no change required: .specify/templates/spec-template.md
	- ✅ no change required: .specify/templates/tasks-template.md
	- ✅ no change required: .specify/templates/commands (directory not present)
- Runtime guidance requiring updates:
	- ✅ updated: AGENTS.md
	- ✅ no change required: README.md
- Deferred TODOs: None
-->

# InfraFactory Constitution

## Core Principles

### I. Modular Design
Components MUST be reusable and self-contained. Provider-specific logic must NOT leak outside 
provider directories. Each feature added to one provider must be evaluated for generalization 
across all providers to maintain architectural consistency.

### II. Provider Symmetry
Each provider MUST enable deployment of N masters and N workers in identical fashion. All 
providers must expose similar variables and outputs. Feature implementations should be as 
provider-agnostic as possible; differences only when technically unavoidable.

### III. Provisioning Workflow (NON-NEGOTIABLE)
Infrastructure provisioning follows this immutable sequence:
1. OpenTofu provisions VMs with provider-specific networking/compute
2. VMs initialized via shared cloud-init templates stored at
	`providers/shared/cloud-init/$type`
3. Providers generate Ansible-compatible inventory from OpenTofu outputs
4. Ansible handles post-provision configuration

Deviation from this workflow requires documented justification.

### IV. Consistent Provider Layout
Every provider directory MUST follow identical file structure. All providers include:
- `keys.tf`, `main.tf`, `variables.tf`, `output.tf` or `outputs.tf`, `providers.tf`,
  `templates.tf`

Shared bootstrap artifacts are centralized outside provider folders:
- cloud-init templates MUST live in `providers/shared/cloud-init/$type`
- inventory templates MUST live in `providers/shared/inventory`

New provider additions MUST conform to this structure without exceptions.

### V. Minimal Provider Differences
Providers should remain feature-parallel. When a provider lacks a feature:
- Implement the closest equivalent, OR
- Document the limitation with explicit rationale.
Avoid provider-specific hacks; prefer solving at abstraction level.

## Implementation Priority

Provider feature development follows strict priority order to optimize feedback cycles:

1. **Libvirt** (Local development): Fast, offline, primary feedback loop
2. **OVH** (Primary cloud target): First production validation
3. **Azure** (Secondary): After Libvirt + OVH proven
4. **DigitalOcean** (Experimental): Lowest priority

New features MUST be validated on Libvirt before cloud implementation.

## Development Workflow

### Work Incrementally
Always implement features field-by-field or module-by-module with testing and commits 
between. Never batch multiple complex changes into single iteration. Pattern:
1. Add ONE field/feature
2. Test and verify
3. Commit with focused message
4. Repeat for next item

### Commit Discipline
- Keep commits small and focused
- Use clear, concise messages (avoid verbose explanations)
- Reference issues with `Resolves: #xxx` format
- Exclude promotional text or "Generated with" messages
- Always run `just` before committing to validate recipes

### No System Modifications
NEVER use sudo, package managers, or system administration commands. Work only within source 
directories. If dependencies are missing, inform the user rather than installing.

## Architecture & Quality

### Schema Coverage Policy
When adding infrastructure features, prefer generic abstractions across providers. Avoid 
single-provider features unless technically necessary. Maintain feature parity or document 
why a provider cannot support a feature.

### Provider Parity Validation
Each change MUST maintain or improve provider parity. Review checklist:
- Does feature apply to all providers?
- If not, why? (document limitation)
- Does it follow the provisioning workflow?
- Are inventory outputs Ansible-compatible?

## Governance

This Constitution supersedes all other practices and project guidance. Amendments require:
- Clear documentation of changed principle(s)
- Rationale for the change
- Version number increment per semver
- PR review and approval

**Version Bump Rules:**
- MAJOR: Backward-incompatible principle removal or redefinition
- MINOR: New principle added or existing principle materially expanded
- PATCH: Clarifications, non-semantic wording updates

Runtime development guidance is defined in [AGENTS.md](AGENTS.md). All infrastructure 
feature additions must verify compliance with these Core Principles before implementation.

**Version**: 1.0.1 | **Ratified**: 2025-03-10 | **Last Amended**: 2026-03-10

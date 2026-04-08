<!--
Sync Impact Report
- Version change: 1.5.0 -> 1.6.0
- Modified principles: Expanded Development Workflow to require synced `env/<PROVIDER>/tfvars.example` files when provider variables change
- Added sections: None
- Removed sections: None
- Implementation Priority updated: No change
- Templates requiring updates:
	- ✅ no change required: .specify/templates/plan-template.md
	- ✅ no change required: .specify/templates/spec-template.md
	- ✅ no change required: .specify/templates/tasks-template.md
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

The common provider capability baseline is:
- SSH key generation
- separate master and worker objects
- per-role compute and disk sizing
- structured extra disks
- shared cloud-init selection and related optional inputs
- kubeconfig retrieval for Kubernetes-enabled cloud-init modes
- Ansible-compatible inventory generation

Provider-specific capabilities may extend this baseline where required by the platform contract.

Exact schema parity is preferred but not mandatory where provider-native contracts are materially
different.

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

Recognized provider-specific differences include:
- **Azure**: NSG rules and cloud-native security/network resources
- **Libvirt**: optional per-role IP/MAC configuration and host-level network mode choices
- **OVH**: closest-equivalent behavior documented before feature implementation

## Implementation Priority

Provider feature development follows strict priority order to optimize feedback cycles:

1. **Libvirt** (Local development): Fast, offline, primary feedback loop - ✅ IMPLEMENTED
2. **Azure** (Primary cloud target): First production validation - ✅ IMPLEMENTED  
3. **OVH** (Secondary): After Libvirt + Azure proven - ✅ IMPLEMENTED
4. **DigitalOcean** (Experimental): Lowest priority - ❌ REMOVED FROM ROADMAP

New features MUST be validated on Libvirt before cloud implementation.

## Development Workflow

### Work Incrementally
Always implement features field-by-field or module-by-module with testing and commits 
between. Never batch multiple complex changes into single iteration. Pattern:
1. Add ONE field/feature
2. Test and verify through the project `just` recipes whenever a matching recipe exists
3. Commit with focused message
4. Repeat for next item

### Commit Discipline
- Keep commits small and focused
- Use clear, concise messages (avoid verbose explanations)
- Reference issues with `Resolves: #xxx` format
- Exclude promotional text or "Generated with" messages
- Use project `just` recipes for tests, validation, checks, and deploy/destroy verification
  instead of calling underlying tools directly when a recipe exists
- Always run `just` before committing to validate recipes
- When provider variable definitions change, keep the matching `env/<PROVIDER>/tfvars.example`
  file in sync

### No System Modifications
NEVER use sudo, package managers, or system administration commands. Work only within source 
directories. If dependencies are missing, inform the user rather than installing.

## Architecture & Quality

### Schema Coverage Policy
When adding infrastructure features, prefer generic abstractions across providers. Avoid 
single-provider features unless technically necessary. Maintain feature parity or document 
why a provider cannot support a feature.

Provider capability decisions SHOULD be checked against `providers/README`, which defines the
current baseline capabilities and known provider-specific extensions.

Provider-native abstractions are acceptable when exact schema parity would hide the real
platform contract. In these cases, specifications MUST document:
- the provider-native input model and why it differs
- any provider-specific cloud resources introduced
- any external service dependency introduced at plan/apply time
- any local artifacts created, updated, or deleted as part of the workflow

### Provider Parity Validation
Each change MUST maintain or improve provider parity. Review checklist:
- Does feature apply to all providers?
- If not, why? (document limitation)
- Does it follow the provisioning workflow?
- Are inventory outputs Ansible-compatible?
- Are provider-specific resources, external dependencies, and local artifact lifecycles
  explicitly captured in spec-kit artifacts?

## Provider Validation Matrix

Provider and feature validation SHOULD be planned against the documented matrix in
`providers/README`.

Minimum expected validation coverage for provider-affecting changes:
- 1 master with `k3s`
- 3 masters / 2 workers with `k3s`
- 1 master with `rke2`
- 3 masters / 2 workers with `rke2`

If a provider cannot support one of these scenarios yet, the limitation MUST be recorded in the
relevant spec-kit artifact and in the implementation status tracked by the repository.

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

**Version**: 1.6.0 | **Ratified**: 2025-03-10 | **Last Amended**: 2026-04-07

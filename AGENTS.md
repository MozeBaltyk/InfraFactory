
# Context for AI Assistants

## Project Overview

InfraFactory is a **multi-cloud infrastructure factory** built with **OpenTofu** and **Just**.

Its goal is to provide a **provider-agnostic, modular, and reproducible way** to provision infrastructure across different platforms.

Each provider implementation should follow the **same architecture and conventions** so infrastructure can be deployed consistently regardless of the backend provider.

Provisioning workflow:

OpenTofu → VM provisioning → cloud-init bootstrap → inventory generation → configuration via Ansible.

---

# Core Principles

1. **Stay modular**
   - Components must be reusable.
   - Avoid provider-specific logic outside provider directories.

2. **Provider symmetry**
   - Each provider must allow deployment of:
     - `N` masters
     - `N` workers

3. **Provisioning workflow**
   - OpenTofu provisions VMs.
   - VMs are initialized using **cloud-init**.
   - Providers must output an **inventory file** compatible with Ansible.

4. **Consistent provider layout**
   - Every provider directory must follow the same structure.

5. **Minimal provider differences**
   - Differences should only exist when technically required.

---

# Schema Coverage Policy

When adding infrastructure features:

- Prefer **generic abstractions** that work across providers.
- Avoid adding features that only work on a single provider unless necessary.
- If a provider lacks a feature:
  - Implement the closest equivalent
  - Or clearly document the limitation.

Providers should remain **as feature-parallel as possible**.

---

# Feature Implementation Priority

**CRITICAL: Read this section before implementing any features.**

When deciding what to implement next, follow this priority order:

### Priority 1: Provider Libvirt

Libvirt is the **local development provider**.

Reasons:
- Works offline
- Fast feedback loop
- Used as the main development and testing platform

All new features should **first be implemented and validated on Libvirt**.

---

### Priority 2: Provider OVH

OVH is the **primary real cloud target**.

Features validated on Libvirt should then be implemented for OVH.

---

### Priority 3: Provider Azure

Azure support is **secondary** and should only be implemented after Libvirt and OVH are functional.

---

### Why this order matters

- Libvirt enables **rapid iteration**
- Cloud providers cost money
- Local reproducibility is critical

---

### When in doubt

If a feature design is unclear:

1. Implement it first for **Libvirt**
2. Ensure it works with **cloud-init + inventory**
3. Then replicate the design to other providers

---

## Project Structure

```
.
├── AGENTS.md                 # This file - context for AI assistants
├── README.md                 # Project status, Justfile usage, roadmap, and TODO tracking
├── ansible
├── assets                    # Images and logo for the README 
├── env                       # Env
│   └── AZ                    # folder for each providers  
│   │    └── tfvars.example        
│   └── KVM
│        └── tfvars.example     
│        └── lab.tfvars       # A tfvars for each env to deploy                                
├── justfile                  # The Orchestrator and main menu for end user
└── providers              
    ├── azure
    ├── libvirt
    ├── ovh
    └── shared/
        ├── clout-init           # Different cloud-init template
        └── inventory/hosts.tpl  # Common Template to be use by each provider and generate hosts.ini for ansible
```

Each provider directory should contain:

```
provider/example
├── keys.tf
├── main.tf
├── variables.tf
├── output.tf
├── templates.tf
```

Shared cloud-init templates are centralized and reused by all providers:

```
providers/shared/cloud-init/
└── $type/
   ├── cloud_init.cfg.tftpl
   └── network_config_*.cfg
```

# Important References

### Providers

Libvirt provider  
https://search.opentofu.org/provider/dmacvicar/libvirt/latest

Azure provider  
https://search.opentofu.org/provider/hashicorp/azurerm/latest

OVH provider  
https://search.opentofu.org/provider/ovh/ovh/latest

---

# Technical Decisions Made

1. **OpenTofu instead of Terraform**
2. **Justfile as CLI orchestrator**
3. **cloud-init for VM bootstrap**
4. **Ansible for post-provision configuration**
5. **Inventory generated automatically from OpenTofu outputs**

---

# Current State

Check **README.md** for the current implementation status.

The README contains:

- roadmap with checkboxes
- implementation status
- next milestones
- known limitations

---

# Working With This Project

Follow these rules strictly.

1. **Do not introduce new project structure without approval**

2. **Do not create new documentation files without authorization**

3. **Never install software or modify the system**

4. **Do not run system commands like:**
   - sudo
   - package managers
   - service restarts

5. **Work only inside the repository source directories**

6. **Preserve modular design**

7. **Avoid provider-specific hacks**

8. **Always keep provider implementations consistent**

9. **Prefer simplicity over clever abstractions**


## Working with This Project

1. **Check TODO.md for current tasks** - single source of truth for what needs to be done
2. **Keep TODO.md updated** - as you complete tasks, mark items as done and update the "Current Status" section
3. **Do NOT create random documentation files** - use existing files (TODO.md, README.md, AGENTS.md)
4. **NEVER create new .md files without explicit user authorization** - ask first before creating any documentation
5. **NEVER install software or modify system configuration** - only work within the source directories. If dependencies are missing, inform the user.
6. **NEVER use sudo or any system administration commands** - no system modifications, no service restarts, no package installs
7. **Run `just` before committing** - that the recipes stay consistent
8. **Preserve design principles**
9.  **Track progress continuously** - update TODO.md after completing each feature or task

## Development Workflow - Work Incrementally

**IMPORTANT**: Always work field-by-field or feature-by-feature with commits in between. Never implement multiple complex features in one iteration.

### The Pattern: Add → Test → Commit → Repeat

1. **Add ONE field or small group of related fields**
   - Update model struct
   - Add schema definition
   - Implement conversion functions (model ↔ XML)

2. **Verify it works**

3. **Commit immediately**
   - Small, focused commit message
   - Example: `feat: add title and description fields`
   - Keep it simple - avoid verbose explanations
   - **DO NOT add promotional text, links, or "Generated with" messages**
   - When referencing issues, use `Resolves: #xxx` format (with colon) following git conventions

4. **Repeat for next field**

### What NOT to Do

- ❌ Don't implement 10+ fields at once
- ❌ Don't batch multiple commits
- ❌ Don't skip testing between changes
- ❌ Don't write verbose commit messages explaining everything
- ❌ Don't say "all tests passing" or obvious statements in commits


# Design Guidelines

### Provider parity

Providers should expose **similar variables and outputs**.

---

### Inventory output

Each provider must generate inventory compatible with `inventory/hosts.tpl`

---

### Cloud-init usage

VMs must be initialized using **cloud-init templates**.
Cloud-init sources MUST come from the shared directory:
`providers/shared/cloud-init/$type`.

Typical responsibilities:

- SSH key injection
- base packages
- hostname configuration

Avoid heavy configuration in cloud-init — that belongs to **Ansible**.

---

# Long-Term Vision

InfraFactory should become a **portable infrastructure factory** capable of deploying clusters across multiple providers with minimal configuration differences.

Goals:

- deterministic infrastructure
- reproducible environments
- provider-agnostic deployments
- automation-first workflows
# Repository contract

What every change to InfraFactory must preserve. Absorbs the former root
`AGENTS.md` governance and the retired `.local/AGENTS.md` agent contract;
where they disagreed with the repo as it is, this file follows the repo.

## Toolchain

OpenTofu `>= 1.6.2, < 2.0.0`, Just `>= 1.0.0`. Provider credentials come from
the environment (`OS_*`/openrc for OVH/OpenStack, Azure CLI, libvirt socket) —
never committed.

## Dependency direction

```text
tfvars
  ↓
provider infrastructure
  ↓
normalized node model
  ↓
bootstrap transport
  ↓
cluster implementation
  ↓
artifacts
  ↓
validation
```

No dependencies in the opposite direction. Shared Talos/K3s/RKE2 logic consumes
the normalized node model, never raw provider resources — unless unavoidable.

## Providers

Supported: `libvirt`, `azure`, `ovh`. Each exposes equivalent logical inputs
and outputs; differences exist only when technically required.

Common capability baseline: SSH key generation, separate master/worker objects,
per-role compute and disk sizing, structured extra disks, shared cloud-init
selection (`default`, `k3s`, `rke2`), username + SSH key injection, optional
Kubernetes inputs (token, kubeconfig), optional ansible-pull inputs.

Provider-specific extensions stay inside provider directories: Azure NSG rules
and cloud-native networking; libvirt per-role IP/MAC plus NAT/bridge and
DHCP/static modes; OVH documents its closest equivalent where parity is
impossible. Prefer generic abstractions for new features; single-provider
features need justification.

Provider directories own cloud infrastructure: VMs, networking, security
groups, load balancers, provider-specific bastions.

## Layout

Each provider directory holds one or more independent root modules plus thin
Just recipes. OVH is currently the only multi-stack provider:

```text
providers/ovh/bastion/    standalone SSH bastion (serves many clusters)
providers/ovh/clusters/   cluster stack (one workspace per cluster)
providers/libvirt/        single-stack provider
providers/azure/          single-stack provider
providers/shared/         cloud-init templates, inventory template, modules
```

Shared modules live in `providers/shared/modules/` (`ipam`, `ssh-keys`,
`cloudinit-renderer`, `ansible-artifacts`, `talos-cluster`). Never copy shared
cluster behavior between provider directories.

## Endpoints

Never conflate `node_address`, `bootstrap_endpoint`, `management_endpoint`,
`kubernetes_endpoint`. For Talos: per-node deterministic bootstrap endpoint,
stable day-2 management endpoint, stable Kubernetes endpoint. Temporary SSH
tunnels must not become user-facing endpoints.

## Artifacts and orchestration

Generated environment artifacts belong under `env/<PROVIDER>/<environment>/`
(keys, `hosts.ini`, `ansible.cfg`, kubeconfig). Do not generate runtime
artifacts inside `providers/`.

The root `justfile` is the public CLI (`validate`, `plan`, `deploy`,
`replace`, `destroy`, plus context and post-check recipes). Recipes stay thin:
no architecture or business logic in Just — that belongs in OpenTofu/modules.
Per-stack justfiles own their lifecycle (tfvars path, workspace, credentials);
the `providers/ovh/justfile` routes to `clusters` by default with explicit
`bastion-*` recipes for the bastion stack.

`gitops/` is an optional management layer (Flux + tofu-controller reconciling
provider stacks from Git). It never changes the provider contract: implementation
stays in `providers/`, inputs and artifacts stay in `env/`.

## Workflow

- Never work directly on `main`; use a feature branch.
- Work incrementally: one field or feature per commit, verify, commit, repeat.
- `env/<PROVIDER>/tfvars.example` is the canonical input template — variable,
  default, or schema changes update it in the same change.
- Keep `docs/plan/summary.md` current; `README.md` holds status, roadmap, and limits.
- No paid cloud operations without explicit approval.
- Changing a shared contract: identify affected providers, update shared
  types/modules, update each provider, update tests, update docs.

## Docs map

`docs/` holds directories, not topical files — `00-repo-contract.md` is the
only content file at root. It orchestrates the repo rules and this map.

| Path | Holds |
|---|---|
| `00-repo-contract.md` | this file — repo rules, orchestration |
| `plan/` | work backlog: `summary.md` index + one file per implementation phase |
| `architectures/` | system architecture + per-provider docs (`00-general`, `ovh/`, `azure/`, `libvirt/`) |
| `procedures/` | operational how-tos (bootstrap, recovery, destroy) |
| `troubleshooting/` | symptom → cause → fix notes |
| `decisions/` | one dated record per architectural decision (context, options, outcome) |

Rules for docs:

- One topic, one place. Never duplicate the contract or another doc — link.
- Decisions get a dated record in `decisions/` (context, options, outcome).
  Work logs may live in a dated directory while in flight, but must be
  distilled or deleted when the work lands — never left to rot.
- No placeholder files. A doc appears when it has content; the table above
  grows with it.
- User-facing workflow, status, roadmap, and limits stay in `README.md`;
  the backlog stays in `docs/plan/`. Docs here are for architecture and
  decisions, not usage.

## Planning process

Implementation planning runs through `docs/plan/` — never as standalone
plan documents. `summary.md` indexes workstreams; each active workstream gets
one file per implementation phase (`phase-00-….md`, …) holding goal, status,
scope, and gate. Mark todos done as phases land.

1. Analysis and work logs may live temporarily in a dated directory while a
   workstream is in flight.
2. Before the workstream closes, dispatch them: goal + todos → `plan/`
   phase files, how-to → `procedures/`, lasting why → `decisions/` as a
   dated record.
3. Delete the work logs once dispatched. Nothing temporary survives at
   `docs/` root or as an orphan directory.

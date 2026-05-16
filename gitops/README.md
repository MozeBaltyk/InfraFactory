# GitOps Layer

`gitops/` contains InfraFactory's optional GitOps management layer.

It installs Flux, Flux Operator, and tofu-controller into an existing Kubernetes management cluster. After that, Flux can reconcile selected InfraFactory provider/environment OpenTofu stacks directly from this repository.

This is separate from VM/node bootstrap:

- `providers/shared/cloud-init/` initializes VMs and installs `default`, `k3s`, or `rke2` node software.
- `gitops/` initializes and operates the Kubernetes-side automation that runs OpenTofu through Flux/tofu-controller.

Use this layer when you want Git to be the control plane for infrastructure changes instead of running the root `just deploy` workflow locally.

---

## Directory layout

```txt
gitops/
├── apps/                  # Flux-managed platform apps and controllers
│   ├── kustomization.yaml  # App tree entrypoint
│   ├── flux-system/        # Flux Operator, Flux instance, tofu-controller
│   └── observability/      # Optional observability stack
├── components/             # Reserved for reusable GitOps components
├── flux/
│   ├── cluster/            # Flux root Kustomizations
│   └── tf/                 # tofu-controller Terraform overlays
│       ├── AZ/
│       ├── KVM/
│       └── OVH/
├── templates/              # Helmfile templates
├── runner/                  # Custom tofu runner image build context and recipes
├── crds.yaml               # CRD rendering source for the GitOps stack
├── flux.yaml               # Flux Operator and Flux deployment Helmfile
└── justfile                # GitOps operation commands
```

Important paths:

- `gitops/flux/cluster/ks.yaml` reconciles `gitops/apps`.
- `gitops/flux/cluster/tf-ks.yaml` reconciles `gitops/flux/tf` after tofu-controller is installed.
- `gitops/flux/tf/<PROVIDER>/kustomization.yaml` controls which provider/environment Terraform overlays are active.

---

## Prerequisites

Run these commands from a workstation that has access to the Kubernetes management cluster.

Expected local tools:

- `kubectl`
- `helmfile`
- `helm`
- `flux`
- `just`
- `python3`
- `tofu` for some local helper commands
- `rg` for log/runner filtering helpers

For KVM/libvirt GitOps runs, the tofu-controller runner also needs SSH access to the libvirt host. The `sync-libvirt-ssh` and `prepare` recipes perform a cluster-local bootstrap Secret sync from `LIBVIRT_HOST_KEY_PATH` or `$HOME/.ssh/ed25519`; this Secret is not Flux-managed desired state.

---

## Provider and environment selection

Most recipes use these environment variables:

```bash
export PROVIDER=KVM   # KVM, AZ, or OVH
export ENV=lab        # environment name
```

Defaults:

- `PROVIDER=KVM`
- `ENV=lab`
- `TARGET_NAMESPACE=flux-system` for `publish-libvirt-artifacts`

If you run `just prepare` without exports, it prepares `KVM/lab`.

Provider tfvars for GitOps live under:

```txt
gitops/flux/tf/<PROVIDER>/<ENV>/<ENV>.tfvars
```

`prepare` creates this file if it is missing, then runs `sync-tfvars` to create or update a cluster-local Kubernetes Secret consumed by tofu-controller. This is a transitional/bootstrap Secret sync performed outside Flux reconciliation, not pure GitOps desired state.

For cloud providers such as AZ and OVH, tfvars may contain provider credentials or other sensitive values. Do not commit plaintext secrets. Long term, prefer SOPS, ExternalSecrets, SealedSecrets, or an equivalent secret-management workflow.

When initializing a missing file, `prepare` copies `env/<PROVIDER>/<ENV>.tfvars` if it exists. Otherwise it copies `env/<PROVIDER>/tfvars.example`. For KVM, it also appends `gitops_artifacts_mode = "gitops"` when the setting is absent.

Example:

```txt
gitops/flux/tf/KVM/test/test.tfvars
```

For KVM GitOps mode, set this in the tfvars:

```hcl
gitops_artifacts_mode = "gitops"
```

This tells the libvirt provider to expose SSH keys, inventory, token, and kubeconfig retrieval details as Terraform outputs instead of writing local files into `env/KVM/<env>/`.

---

## Main workflows

### 1. Deploy the GitOps controllers

From the repository root:

```bash
just -f gitops/justfile deploy
```

Or from inside `gitops/`:

```bash
just deploy
```

This recipe:

1. Applies namespaces from `gitops/apps/*/namespace.yaml`.
2. Renders and applies CRDs from `crds.yaml`.
3. Syncs Flux and Flux Operator using `flux.yaml`.

### 2. Prepare a provider/environment Terraform overlay

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile prepare
```

This recipe:

1. Creates `gitops/flux/tf/<PROVIDER>/<ENV>/<ENV>.tfvars` if it is missing.
2. Generates or updates `gitops/flux/tf/<PROVIDER>/<ENV>/terraform.yaml`.
3. Ensures the provider kustomization exists.
4. Syncs the provider/environment tfvars into a cluster-local bootstrap Secret that is not Flux-managed.
5. For KVM, syncs the libvirt host SSH key as a cluster-local bootstrap Secret.

For a new environment:

```bash
PROVIDER=KVM ENV=test2 just -f gitops/justfile prepare
```

Then edit the generated tfvars before activating/committing if the defaults are not correct for that environment.

`prepare`/`scaffold` rewrites the generated `terraform.yaml` and `kustomization.yaml` for the selected provider/environment. If an overlay has hand-maintained fields such as `approvePlan`, `runnerPodTemplate`, or a custom tfvars path, review the diff before committing.

For KVM, override the SSH key source if needed:

```bash
LIBVIRT_HOST_KEY_PATH=/path/to/key PROVIDER=KVM ENV=test just -f gitops/justfile prepare
```

### 3. Activate the overlay

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile activate
```

This adds `./<ENV>` to `gitops/flux/tf/<PROVIDER>/kustomization.yaml`.

Only active overlays are reconciled by Flux.

### 4. Commit and push GitOps changes

The Flux instance watches this repository. After `prepare` and `activate`, commit and push the generated or updated files so Flux can see them.

### 5. Reconcile Flux

```bash
just -f gitops/justfile reconcile
```

This asks Flux to reconcile the Git source and the root GitOps Kustomizations.

---

## Useful commands

List recipes:

```bash
just -f gitops/justfile --list
```

List scaffolded overlays and whether they are active:

```bash
just -f gitops/justfile list
```

Show tofu-controller status for the selected provider/environment:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile status
```

Watch the Terraform resource:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile watch
```

Describe the Terraform resource:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile describe
```

Tail tofu-controller logs for the selected Terraform resource:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile logs
```

Show runner pods:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile runner
```

Show backend locks:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile locks
```

Show recent events:

```bash
just -f gitops/justfile events
```

Deactivate an overlay:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile deactivate
```

Delete Flux and GitOps Helm releases:

```bash
just -f gitops/justfile delete
```

---

## KVM/libvirt artifact bridge

For local/manual KVM deployments, artifacts are written under:

```txt
env/KVM/<ENV>/
```

The helper below publishes those local artifacts into a Kubernetes Secret so GitOps-managed components can consume them:

```bash
PROVIDER=KVM ENV=lab just -f gitops/justfile publish-libvirt-artifacts
```

Required local files:

- `.key.private`
- `.key.pub`
- `.token`
- `hosts.ini`
- `ansible.cfg`

If `kubeconfig` is missing locally, the helper tries to fetch it using the `gitops_kubeconfig_*` Terraform outputs from the libvirt workspace. That fallback uses local `tofu`, `ssh`, and remote `sudo cat`, so the local machine must have access to the libvirt workspace and passwordless SSH/sudo access to the target node.

---

## Notes and caveats

- Provider kustomization files are the activation gate. A Terraform overlay can exist under `gitops/flux/tf/<PROVIDER>/<ENV>/` without being reconciled until `gitops/flux/tf/<PROVIDER>/kustomization.yaml` references `./<ENV>`.
- `prepare` performs a cluster-local bootstrap Secret sync for tfvars and, for KVM, SSH material. These Secrets are created imperatively in the target cluster, are not committed to Git, and are not Flux-managed.
- This bootstrap Secret sync is transitional behavior, not pure GitOps. For cloud provider credentials, avoid plaintext tfvars in Git and prefer SOPS, ExternalSecrets, or SealedSecrets long-term.
- `terraform.yaml` overlays are committed to Git and consumed by tofu-controller.
- KVM/libvirt GitOps execution requires the runner to reach the libvirt host over SSH.
- The Flux instance currently points at a specific Git branch in `gitops/apps/flux-system/flux-instance/app/helmrelease.yaml`. Update that branch when moving this workflow to another long-lived branch.
- `delete` runs Helmfile destroy for `flux.yaml` and `crds.yaml`, then performs fallback cleanup for Flux CRDs matching `.fluxcd.io`.

---

## Troubleshooting

Check Flux/tofu-controller state:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile status
```

Watch reconciliation:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile watch
```

Inspect tofu-controller logs:

```bash
PROVIDER=KVM ENV=test just -f gitops/justfile logs
```

Check recent events:

```bash
just -f gitops/justfile events
```

If KVM plans fail in tofu-controller, verify:

1. `gitops_artifacts_mode = "gitops"` is set in the KVM GitOps tfvars.
2. The libvirt SSH Secret exists:

   ```bash
   kubectl -n flux-system get secret libvirt-ssh-kvm-<ENV>
   ```

3. The Terraform tfvars Secret exists:

   ```bash
   kubectl -n flux-system get secret tfvars-kvm-<ENV>
   ```

4. The runner can reach the configured libvirt host.

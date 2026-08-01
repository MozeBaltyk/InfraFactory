# InfraFactory Talos Capability — Implementation Brief

## Goal

Implement Talos as an optional cluster bootstrap mode for all providers.

Talos is selected with the existing selector:

```hcl
cluster.cloud_init_selected == "talos"
```

The variable name is poor because Talos does not use cloud-init, but keep this selection logic for compatibility.

Talos must be treated as a separate bootstrap path from the existing Linux + cloud-init + Ansible flows:

```text
Current flow:
OpenTofu -> VM provisioning -> cloud-init -> Ansible -> kubeconfig

Talos flow:
OpenTofu -> VM provisioning with Talos image -> Talos machine config apply -> Talos bootstrap -> kubeconfig
```

## Scope

### Shared module

Create a shared OpenTofu module:

```text
providers/shared/tf/talos/
├── main.tf
├── variables.tf
├── outputs.tf
└── templates/
```

The module is responsible only for Talos configuration and bootstrap artifacts:

- Talos machine secrets
- Talos machine configuration generation
- Talos client configuration generation
- Talos machine configuration apply
- Talos bootstrap against one control-plane node
- Talos kubeconfig retrieval
- optional local `talosconfig` and `kubeconfig` artifacts under `env/<PROVIDER>/<env>/`

### Provider responsibility

Each provider continues to own:

- VM lifecycle
- Talos-compatible image selection
- disks
- network resources
- security groups / firewall / NSG rules
- IP addressing
- inventory-like node metadata passed into the shared Talos module

Do not put provider-specific VM, image, networking, or security logic in the shared Talos module.

## Provider Implementation Order

1. Libvirt
2. Azure
3. OVH

Validate the design on Libvirt first, then copy the same provider contract to Azure, then define the closest equivalent for OVH.

## Mode Gating

Providers must gate Talos resources from the existing selector.

```hcl
locals {
  talos_enabled = var.cluster.cloud_init_selected == "talos"
}
```

Use `count` or `for_each` to avoid creating Talos module resources in non-Talos modes.

Prefer `for_each` for clearer references:

```hcl
locals {
  talos_enabled     = var.cluster.cloud_init_selected == "talos"
  cloudinit_enabled = !local.talos_enabled
}
```

### `count` example

```hcl
module "talos" {
  count  = local.talos_enabled ? 1 : 0
  source = "../shared/tf/talos"

  cluster_name     = var.cluster.name
  endpoint         = local.talos_endpoint
  masters          = local.talos_masters
  workers          = local.talos_workers
  kubernetes_version = var.cluster.kubernetes_version
  talos_version      = var.cluster.talos_version
}
```

### `for_each` example

```hcl
module "talos" {
  for_each = local.talos_enabled ? { enabled = true } : {}
  source   = "../shared/tf/talos"

  cluster_name = var.cluster.name
  endpoint     = local.talos_endpoint
  masters      = local.talos_masters
  workers      = local.talos_workers
}
```

Guard provider outputs because the module is absent when Talos is disabled:

```hcl
output "talosconfig" {
  value     = local.talos_enabled ? module.talos["enabled"].talosconfig : null
  sensitive = true
}

output "talos_kubeconfig" {
  value     = local.talos_enabled ? module.talos["enabled"].kubeconfig : null
  sensitive = true
}
```

## Disable cloud-init and Ansible in Talos Mode

When `cluster.cloud_init_selected == "talos"`:

- do not render shared cloud-init templates
- do not attach cloud-init ISO/user-data/custom-data
- do not rely on SSH access
- do not run or configure Ansible bootstrap flows
- do not generate Ansible inventory as the primary bootstrap contract

Provider resources must use Talos-native install media or Talos-compatible image bootstrapping instead.

```hcl
locals {
  use_cloud_init = var.cluster.cloud_init_selected != "talos"
}
```

```hcl
resource "libvirt_cloudinit_disk" "default" {
  count = local.use_cloud_init ? 1 : 0
  # existing cloud-init logic
}
```

Existing K3s/RKE2 Ansible resources must remain gated to non-Talos modes:

```hcl
locals {
  k8s_master_user_data_enabled = contains(["k3s", "rke2"], var.cluster.cloud_init_selected) && var.infra.masters.count > 0 && var.infra.masters.user_data_enabled
}
```

Do not run `check_cloudinit`, `reconcile_tls_san`, or `fetch_kubeconfig` through Ansible when Talos is selected.

## Required Provider Inputs

Update each provider contract and matching `env/<PROVIDER>/tfvars.example`.

Minimum cluster inputs:

```hcl
cluster = {
  name                = "lab"
  cloud_init_selected = "talos"
  kubernetes_version  = "v1.30.0"
  talos_version       = "v1.7.0"
}
```

If the existing `cluster` object cannot be extended cleanly, add a provider-parallel top-level `talos` object. Keep this object generic and consistent across providers.

Provider-specific inputs may include Talos image IDs/URLs, but keep names and structure as parallel as possible across providers.

Example provider image contract:

```hcl
talos = {
  image_id  = null
  image_url = null
}
```

Node metadata passed to the shared module must be provider-normalized:

```hcl
masters = [
  {
    name       = "lab-master-0"
    private_ip = "192.168.122.10"
    public_ip  = null
  }
]

workers = [
  {
    name       = "lab-worker-0"
    private_ip = "192.168.122.20"
    public_ip  = null
  }
]
```

Use stable node names as map keys. Do not use dynamically discovered IP addresses as `for_each` keys.

## Shared Talos Module Inputs

```hcl
variable "cluster_name" {
  type = string
}

variable "endpoint" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "talos_version" {
  type = string
}

variable "masters" {
  type = list(object({
    name       = string
    private_ip = string
    public_ip  = optional(string)
  }))
}

variable "workers" {
  type = list(object({
    name       = string
    private_ip = string
    public_ip  = optional(string)
  }))
}
```

Recommended node contract if map keys are preferred:

```hcl
variable "controlplane_nodes" {
  type = map(object({
    ip             = string
    hostname       = string
    install_disk   = optional(string, "/dev/vda")
    config_patches = optional(list(string), [])
  }))
}

variable "worker_nodes" {
  type = map(object({
    ip             = string
    hostname       = string
    install_disk   = optional(string, "/dev/vda")
    config_patches = optional(list(string), [])
  }))
}
```

Optional inputs may be added only if they preserve provider parity:

- cluster endpoint override
- CNI selection
- pod/service CIDRs
- control-plane certificate SANs
- machine install disk selector
- generated artifact output directory

## Shared Talos Module Outputs

Required outputs:

```hcl
output "talosconfig" {
  value     = local.talosconfig
  sensitive = true
}

output "kubeconfig" {
  value     = local.kubeconfig
  sensitive = true
}

output "controlplane_machine_configs" {
  value     = local.controlplane_machine_configs
  sensitive = true
}

output "worker_machine_configs" {
  value     = local.worker_machine_configs
  sensitive = true
}

output "endpoint" {
  value = var.endpoint
}
```

Provider-level outputs should expose only the shared outputs needed by users and automation, preserving sensitivity.

Provider-level normalized cluster outputs should remain consistent with existing provider outputs:

- `controller_ips`
- `worker_ips`
- `public_ips`
- `private_ips.controllers`
- `private_ips.workers`
- `private_ips.all`
- `kubeconfig_command` or Talos-specific equivalent when artifacts are written locally

Do not expose Talos secrets in plain text outputs.

## Expected Talos Provider Resources

The shared module will likely use the Talos OpenTofu/Terraform provider resources/data sources equivalent to:

```text
talos_machine_secrets
talos_machine_configuration
talos_machine_configuration_apply
talos_machine_bootstrap
talos_cluster_kubeconfig
```

Keep provider configuration generic. Do not put dynamic VM IP addresses in the Talos provider block. Pass node IPs into resources instead.

## Dependency Graph

Expected flow:

```text
provider variables
  -> provider VM/image/network/security resources
  -> normalized node metadata locals
  -> shared Talos module
  -> Talos machine configs / talosconfig / kubeconfig
  -> optional artifact files under env/<PROVIDER>/<env>/
```

The shared Talos module depends on provider-computed node addresses. Providers must ensure IPs are known before Talos config generation when possible.

Avoid reverse dependencies where shared Talos logic controls provider infrastructure.

Expected resource order inside a provider:

```text
provider VM resources
  -> provider network wait / IP discovery if required
  -> locals.talos_controlplane_nodes and locals.talos_worker_nodes
  -> module.talos
  -> sensitive outputs / optional local files
```

Use explicit `depends_on` at the module call only when provider resources do not create enough implicit dependencies.

```hcl
module "talos" {
  for_each = local.talos_enabled ? { enabled = true } : {}
  source   = "../shared/tf/talos"

  # inputs...

  depends_on = [
    libvirt_domain.vms,
  ]
}
```

## State and Secrets Risks

Talos artifacts contain secrets and must be treated as sensitive:

- `talosconfig`
- `kubeconfig`
- machine configuration secrets
- bootstrap tokens/certificates

Implementation requirements:

- mark secret outputs as `sensitive = true`
- avoid printing secrets in normal outputs
- document that OpenTofu state will contain sensitive Talos material
- do not commit generated artifacts
- write artifacts only into environment-specific ignored paths when existing workflow supports it
- prefer minimal secret surface in provider outputs

If local files are written, follow the existing environment artifact convention:

```text
env/<PROVIDER>/<env>/talosconfig
env/<PROVIDER>/<env>/kubeconfig
```

Generated artifacts must remain ignored by git.

## Provider-Specific Notes

### Libvirt

First implementation target.

- Prefer static or predictable IPs for the first iteration.
- Select a Talos-compatible image/ISO/qcow2 in the Libvirt provider.
- Disable `libvirt_cloudinit_disk` and cloud-init attachment in Talos mode.
- Ensure the OpenTofu runner can reach Talos API port `50000` and Kubernetes API port `6443`.

### Azure

Second implementation target.

- Talos image handling may require a custom image, shared image, marketplace image, or uploaded disk.
- NSG rules must allow required Talos/Kubernetes API access from the operator location.
- Keep Azure-specific image and NSG details in `providers/azure`.

### OVH

Third implementation target.

- Define closest equivalent behavior before implementation.
- Image/bootstrap support may require provider-specific investigation.
- Keep OVH load balancer/private network behavior provider-local.

## Validation Strategy

Validate with project `just` recipes when available.

Minimum matrix:

1. Libvirt single-master Talos cluster
2. Libvirt multi-master plus workers Talos cluster
3. Azure single-master Talos plan/apply review
4. Azure multi-master plus workers plan review
5. OVH closest-equivalent plan review after contract definition

For each provider:

- `cloud_init_selected = "talos"` creates no cloud-init resources
- non-Talos modes still create existing cloud-init resources
- Ansible bootstrap is skipped in Talos mode
- generated node metadata has correct master/worker separation
- Talos module is absent from state in non-Talos modes
- Talos outputs are marked sensitive
- provider `tfvars.example` includes the Talos inputs

Suggested validation commands:

```bash
PROVIDER=KVM ENV=lab just validate
PROVIDER=AZ ENV=test just validate
PROVIDER=OVH ENV=ovh-rkji just validate
tofu fmt -check -diff providers/libvirt providers/azure providers/ovh providers/shared/tf/talos
git diff --check
```

Do not run destructive apply/destroy unless explicitly requested.

## Project Constraints

- Preserve provider parity.
- Keep provider-specific behavior inside provider directories.
- Keep shared Talos module provider-agnostic.
- Do not add provider hacks to make one backend work differently.
- Do not change the existing selector name; use `cluster.cloud_init_selected == "talos"`.
- Keep Libvirt first, Azure second, OVH third.
- Update `env/<PROVIDER>/tfvars.example` whenever provider variables or deployment inputs change.
- Keep cloud-init templates under `providers/shared/cloud-init/` unused in Talos mode.
- Keep Ansible as non-Talos post-provision configuration only unless a separate Talos-native design is approved.

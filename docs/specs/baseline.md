# Spec — provider baseline (all providers)

Normative MUST baseline every provider module implements; provider
differences exist only when technically required (see the per-provider
specs in `ovh/`, `azure/`, `libvirt/` and the per-provider sections of
`providers/README`). Test scenarios that
prove it live in the `providers/README` matrix.

## 1. SSH and secrets

* Generate an RSA 4096-bit SSH key pair per deployment into
  `env/<PROVIDER>/<workspace>/` (never committed).
* Talos mode generates neither SSH keys nor k3s/rke2 tokens.

## 2. Compute topology

* N masters, N workers, N standalone VMs, independently configurable
  where the provider allows.
* Separate `masters`, `workers`, `vms` objects in the variable schema;
  per-role compute sizing (CPU/RAM/disk) and structured extra disks
  (`size_gb`, `mount_path`, `filesystem`, `label`).
* Scale up/down by changing counts.
* VM-only deployments: `cluster.cloud_init_selected = "default"`,
  `masters.count = 0`, `workers.count = 0`, `vms.count >= 1`.

## 3. Cloud-init

* Variant selected by `cluster.cloud_init_selected` (`default`, `k3s`,
  `rke2`); sources MUST reference `providers/shared/cloud-init/$type/`.
* Inject username + SSH public key; optional OS upgrade via
  `cluster.package_upgrade_enabled`; per-role `user_data_enabled` (off
  means no cloud-init injected for that role).
* Optional inputs: `extra_packages`, `k3s` / `rke2` blocks (version,
  token, TLS SANs, etcd and component toggles), auto-generated cluster
  token (`.token` file), `ansible.pull` block.

## 4. Ansible integration

* Inventory compatible with `providers/shared/inventory/hosts.tpl` with
  shared `CONTROLLERS`, `WORKERS`, `VMS` groups; generated `ansible.cfg`
  carries remote user, inventory path, private key.
* Kubernetes post-steps, gated by Kubernetes cloud-init mode and role
  `user_data_enabled`: bounded cloud-init readiness check, TLS SAN
  reconciliation, kubeconfig fetch with endpoint rewrite. VM-only
  `default` deployments skip them.

## 5. Outputs and identity

* `cluster_nodes` with `controller_ips`, `worker_ips`, `vm_ips` on every
  provider, plus `public_ips` / `private_ips` detail only where the
  provider has that address model (Azure has both; OVH exposes
  `ssh_first_master` instead; libvirt has no public IPs by design).
  Extra per-provider keys are allowed; absent model detail is not a
  violation.
* `kubeconfig_command` when Kubernetes is enabled; Kubernetes API
  endpoint output or nested detail where the provider supports it.
* `cluster.id` for resource naming, `cluster.domain` for DNS,
  `cluster.node_name_format` (`serial` or `role`).

## 6. State security

Local OpenTofu state holds private keys, tokens, and provider data.
Production/team deployments REQUIRE a user-selected encrypted remote
backend with locking; the repository prescribes none.

## 7. Acceptance

Every provider-affecting change preserves, at minimum: single-master k3s
flow, HA multi-master + workers flow, both `k3s` and `rke2` modes,
VM-only `default` flow, and generated inventory/kubeconfig artifacts
where applicable.

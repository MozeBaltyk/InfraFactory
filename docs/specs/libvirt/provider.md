# Spec — libvirt provider

libvirt-specific normative spec on top of `../baseline.md`. Distilled
from the libvirt sections of `providers/README` (which keeps the
descriptive matrix); on conflict, this file wins. libvirt is the primary
development provider (see `AGENTS.md` priority: libvirt → Azure → OVH).

## 1. Connection

* Local `qemu:///system` by default; remote hypervisors via
  `qemu+ssh://` in the `libvirt` config block (`remote`, `user`,
  `host`, `system`).
* The operator needs `libvirt-daemon`, `libvirt-dev`, `mkisofs` plus
  `libvirt`/`kvm` group membership.

## 2. Network and addresses

* Mode `nat`, `route`, or `bridge`, each with validated mode-specific
  requirements; `ip_type` `dhcp` or `static`.
* Optional per-role `ip_addresses` and `mac_addresses` lists (unique to
  libvirt, the only static-IP source of truth here).
* Gateway: optional, auto-derived from CIDR for nat/route, required for
  bridge+static. DNS via `network.extra_dns` (default
  `["8.8.8.8", "8.8.4.4"]`); the libvirt gateway is prepended in
  nat/route.
* There is no `region` concept and no public IP model: inventory uses the
  operator endpoint (coalescing static IP, runtime IP, FQDN).

## 3. Nodes and images

* Per-role CPU/RAM directly on `infra.masters` / `infra.workers` (`cpu`,
  `memory_gb`); `disk_size` per role.
* `cluster.node_name_format`: `serial` (one shared sequence, stable only
  while the master count is fixed) or `role` (per-role numbering, safer
  for scaling).
* Cloud-init delivery via `libvirt_cloudinit_disk` ISO using the shared
  `network_config.cfg.tftpl` (DHCP and static + DNS).
* Storage pool at `cluster.factory_root_path` (default `/srv`); guests
  run with `host-passthrough` CPU mode.

## 4. Artifact modes

* `gitops_artifacts_mode` in `{"manual", "gitops"}`; manual writes local
  files.

## 5. Limitations (normative)

* VM-only deployments require `cloud_init_selected = "default"`, no
  workers, and at least one `infra.vms` instance.
* `just replace NAME` targets `libvirt_domain.vms[NAME]`.

## 6. Acceptance

Baseline §7 for the KVM matrix rows (VM-only `default`, single-master
and HA `k3s`, single-master and HA `rke2`).

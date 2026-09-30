# TO2 — Talos image and first-boot network — pending

## Goal

Boot a future scratch Talos VM with a deterministic private address without
changing any non-Talos graph.

## Scope

- Implement the TO0 image-ownership decision behind
  `cloud_init_selected == "talos"`; image names/versions must be unambiguous
  per region and missing or duplicate matches must fail before VM creation.
- Add Talos inputs and provider requirements by reusing
  `providers/shared/modules/talos-cluster` contracts and libvirt's version
  surface; keep OVH-specific image behavior inside `providers/ovh/`.
- Implement the selected first-boot network path conditionally. Preserve the
  current config-drive, `dhcp = false`, netplan, NIC ordering, and route scrub
  byte-for-byte for `default`, K3s, and RKE2.
- Talos must not render `providers/shared/cloud-init/talos`, execute Ubuntu
  netplan/systemd/sshd payloads, or create node SSH access.
- Add checks for image architecture/firmware compatibility, deterministic
  private address, gateway/DNS availability, and the verified/explicit install
  disk contract. This phase performs offline validation only.

Rollback is deletion of Talos-only conditionals/resources before any live
deployment; legacy resource addresses and state remain untouched.

## Gate TO-G2 — go/no-go

**Go:** `just validate` for OVH, KVM, and AZ plus TO1 tests are green; fixture
plans show Talos-only image/network changes and no legacy diffs. **No-go:** a
legacy expression, resource address, provider behavior, or rendered user-data
changes. Revert this phase; no authenticated apply.

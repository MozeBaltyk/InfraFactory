# First-boot DNS race — `cloud-init error` on private-only nodes

Symptom: `cloud-init status` = `error`; `check_cloudinit` logs
`package_update_upgrade_install → "Temporary failure resolving
'archive.ubuntu.com' / 'security.ubuntu.com'"`. Yet `kubectl get nodes` is all
`Ready` and `nfs-common` is installed.

## Cause

Two distinct races are easily conflated; this is the **DNS** one, not egress:

- The early `package_update_upgrade_install` module (driven by `packages:` +
  `package_update: true` in the shared templates) runs in cloud-init's
  **config** stage.
- A private-only node's DNS (`213.186.33.99`) comes only from our netplan `99`
  file and the `FallbackDNS` drop-in — both written via `write_files` in the
  same config stage, but actually applied by `netplan apply` / the oneshot
  service later.
- So during the package stage, systemd-resolved has **no usable upstream** → apt
  resolution fails. By the `runcmd` (final) stage DNS has converged, so
  `rke2-install.sh` and `apt-get install nfs-common` succeed.

Egress was the *old* failure mode and is fixed (gateway ordered before VMs).
This race is independent of egress and currently unavoidable with `dhcp=false`
subnets + config-drive delivery.

## Consequence

Base `packages:` (curl, bash-completion, qemu-guest-agent) are not installed
by cloud-init; cloud-init reports `error`. The cluster still forms (rke2 +
nfs via `runcmd`), so `check_cloudinit` passes (it only fails when cloud-init
errored **and** no k8s service is running) — it just stays noisy.

## Fix (planned)

1. Move the base package install out of `packages:` into `runcmd` (runs after
   DNS/netplan converge), with the existing apt-retry guard; or
2. Set `dns_nameservers` on the subnet so `50-cloud-init.yaml` carries DNS from
   the network stage (removes the dependence on our `99` file).

Tracked in `../../plan/summary.md`; context in
`../architectures/ovh/03-network.md` §8.2.

## Scale reminder (related, distinct)

After adding/removing nodes, sync the bastion `clusters[].{masters,workers}`
and re-run `just ovh::bastion::converge` — otherwise `PermitOpen` does not
cover the new node IPs and cluster Ansible cannot reach them
(`Connection closed by UNKNOWN port 65535`).
# Gateway SNAT DOWN — private nodes have no internet egress

Symptom: the cluster apply gets stuck at `check_cloudinit` (tainted). Every
node reports `cloud-init status` = `error` and the Kubernetes service is
inactive (`rke2-server`/`rke2-agent`, or `k3s`/`k3s-agent`). The nodes never
joined the cluster because the install never happened.

## Cause

The OVH gateway's **SNAT port** is `DOWN`. The gateway router itself is
`ACTIVE` with `enable_snat: true` and a public IP, but its centralized SNAT
namespace (`device_owner = network:router_centralized_snat`) never came up, so
outbound traffic from private nodes is never NATed onto the public network.

This is **distinct from the DNS race**
([`ovh-cloud-init-dns-race.md`](ovh-cloud-init-dns-race.md)): there, DNS is the
only casualty and `runcmd` still installs rke2/k3s once DNS converges. Here
egress itself is dead, so *everything* that needs the internet fails — the
config-stage `packages:` install, the `runcmd` `curl https://get.rke2.io`
(`curl: (28) Resolving timed out`), and `apt-get install nfs-common` (hence
`mount: /mnt/nfs_1: bad option`).

The gateway is created before the VMs and only returns once it is `READY`, but
`READY`/`ACTIVE` do not guarantee the SNAT namespace is functional. Seen
2026-09-23 on `simpl-dest-dev-01` (recovered by gateway recreation).

Current greenfield deployments reserve every Kubernetes node IP with a managed
Neutron port before gateway creation. Older/partial deployments can instead
fail during VM creation when the centralized SNAT port has already claimed a
deterministic node address; migrate through a reviewed plan and VM replacement,
not by deleting service-owned ports or editing state.

## Diagnosis

From a node, the telltale split is: the private gateway answers but nothing
beyond it does.

```bash
# node: gateway is reachable…
ping 10.0.10.1            # 0% loss (gateway internal IP)
# …but egress is not
getent hosts get.rke2.io  # times out
curl -fsSLI https://1.1.1.1 # "Couldn't connect"
```

On the control plane, inspect the gateway's SNAT port:

```bash
openstack router list
openstack router show <gateway-id>            # interfaces_info lists two IPs: .1 + one SNAT IP
openstack port list --network <net-id> -c "Fixed IP Addresses" -c "Device Owner" -c Status
```

The port with `device_owner network:router_centralized_snat` shows **DOWN**.
A healthy cluster's equivalent port shows **ACTIVE** — compare side by side.

Quick check (no node SSH) — `scripts/ovh/check-gateway-egress.sh` / the
`PROJECT=<project> ENV=<env> just ovh::check-gateway` recipe exits non-zero when this port is
`DOWN`. Note `openstack port list` hides `device_owner` on OVH unless you pass
`--device-owner` (or `--long`), which is what that script relies on.

## Fix

1. Review current configuration, then recreate the gateway through the
   backend-aware recipe. This is a paid apply and can include other pending
   cluster changes, so plan first:

   ```bash
   PROJECT=<project> ENV=<env> just ovh::plan
   PROJECT=<project> ENV=<env> just ovh::replace-gateway
   ```

   Re-check the SNAT port is now `ACTIVE`, then confirm egress from a node
   (`getent hosts get.rke2.io` succeeds).

2. Re-run the install script already on every node (first-boot cloud-init
   failed it; the script is idempotent and self-contained):

   ```bash
   # first master (initializes etcd)
   sudo /usr/local/bin/rke2-install.sh        # or k3s-install.sh
   # wait until: systemctl is-active rke2-server → active, and port 9345 open (k3s: 6443)
   # then the remaining masters + workers in parallel (wait_for_first_master gates them)
   sudo /usr/local/bin/rke2-install.sh        # masters: rke2-server, workers: rke2-agent
   ```

3. Re-run the deploy so the ansible flow completes (check_cloudinit → TLS SAN
   reconcile → kubeconfig fetch):

   ```bash
   PROJECT=<project> ENV=<env> just ovh::cluster-deploy
   ```

4. If the NFS mount also failed during first boot (nfs-common not installed),
   repair it per node:

   ```bash
   sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
   sudo mount -a
   ```

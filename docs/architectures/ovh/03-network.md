# OVH network — context, full process, and known problems

Migrated from `.local/network_ovh.md` during the docs cleanup. Path note: the
cluster stack now lives in `providers/ovh/clusters/` (moved from
`providers/ovh/`); bare `providers/ovh/<file>.tf` references below mean
`providers/ovh/clusters/<file>.tf`. The embedded bastion
(`clusters/bastion.tf`) is migrating to the standalone
`providers/ovh/bastion/` module — see `docs/plan/` (bastion split phases)
and `docs/decisions/2026-09-18-ovh-bastion-split.md`.

## 0. Context: what are we trying to achieve?

InfraFactory is a multi-cloud factory (libvirt / Azure / OVH) with one rule:
every provider provisions the same way — OpenTofu creates VMs, cloud-init
bootstraps them, OpenTofu emits an Ansible inventory, Ansible builds the
cluster (k3s/rke2). Provider differences must stay inside provider
directories and stay minimal.

On OVH that means, concretely:

* A private Neutron network (`10.0.20.0/24`-style, per-env CIDR) where every
  node gets a **deterministic static IP** (`cidrhost(...)`: masters first,
  then workers, then extra VMs, then bastion). Deterministic because the
  inventory, TLS SANs, flannel interface pinning, and `PermitOpen` rules all
  derive from those IPs.
* Two topologies from the same code:
  * **Normal** — every node is dual-homed: `ens3` = public (Ext-Net, DHCP),
    `ens4` = private (static). SSH straight from the internet.
  * **LB + ssh-jump** — cluster nodes are **private-only** (`ens3` = private,
    no public NIC at all) and a **bastion** keeps the public entry. All node
    SSH goes through the bastion (`ProxyCommand`), kube API goes through an
    Octavia LB with a floating IP.
* A bastion that is SSH-jump only, never a router (`ip_forward=0`,
  `AllowTcpForwarding local`, `PermitOpen <nodes>:22`).
* Internet egress for private-only nodes via the Neutron gateway (router
  SNAT) — first boot needs it (`curl https://get.rke2.io`, package installs).
  That forces `enable_gateway_ip = true` on the subnet whenever the LB is on.
* Clean destroy (no leftover Neutron ports blocking subnet deletion).

So the network layer has exactly one hard job: **every boot, every node must
converge to exactly one correct default route** — via public on dual-homed
nodes, via the private gateway on private-only nodes — with static private
IPs, unattended, and surviving reboots.

## 1. The pieces

| Actor | Role | Lives in |
|---|---|---|
| Neutron | Private net/subnet (`cidr`, `vlan_id`), gateway `.1`, `dhcp = false`, Ext-Net public net | `clusters/network.tf` |
| Nova (`openstack_compute_instance_v2`) | VMs, ports with fixed IPs, **config-drive** (virtual CD-ROM carrying `user_data` + `network_data.json`) | `clusters/main.tf`, `clusters/bastion.tf` |
| cloud-init | 3 stages: **network** (renders `50-cloud-init.yaml` from `network_data.json`) → **config** (`write_files`, `runcmd`) → **final** | shared `cloud-init/*/cloud_init.cfg.tftpl` + OVH merge |
| netplan | Applies the **merge** of all `/etc/netplan/*.yaml`, alphabetically. No syntax exists to *remove* something another file added | guest `/etc/netplan/` |
| Our guest files | `99-infrafactory-ovh-private.yaml` (intent), `infrafactory-ovh-private-netplan.sh` + `.service` (reconciliation), sshd hardening | `clusters/templates.tf`, `clusters/bastion.tf` |
| Security groups | Bastion SG (`:22` from ingress CIDRs, incl. operator IP) and cluster SG, attached via `port_secgroup_associate` resources | `clusters/network.tf`, `clusters/bastion.tf` |
| LB + FIP + gateway | Octavia LB (`:6443`) on the private net, floating IP (stable endpoint), gateway required by the LB | `clusters/network.tf` |

NIC order is load-bearing: Nova attaches NICs in the order of the `network`
blocks, and the guest names them in that order. Dual-homed = Ext-Net first
(`ens3` = public) + private second (`ens4` = private). Private-only = one NIC
(`ens3` = private). `templates.tf` (`ovh_private_interface_names`) and the
netplan template hard-code this mapping.

## 2. Full process

### 2a. Apply time (control plane)

1. Private network + subnet are created (`dhcp = false`, gateway on iff LB).
2. Image/flavor lookup, SSH keys, shared cloud-init rendering per node.
3. OVH merge per node: base cloud-config + `write_files` (netplan `99` file,
   scrub script + service, sshd config) + `runcmd` (`netplan generate/apply`,
   `daemon-reload`, enable service, `sysctl`, sshd verify).
4. Instances boot with `config_drive = true`, NICs in fixed order, fixed
   private IPs. Public IPv4s come back in Nova state (no re-read needed).
5. Port lookups → SG association (`enforce = true`), gateway → LB → FIP.
6. `bastion_cloudinit_ready` provisioner SSH-probes the bastion
   (`cloud-init status --wait`, ~10 min fail-fast). Then Ansible artifacts.

### 2b. Boot time (guest, every boot)

1. Guest reads **config-drive**: `user_data` (users, keys, hostname, our
   files, our `runcmd`) and `network_data.json` (both NICs, **always
   including the subnet gateway**).
2. cloud-init **network stage** renders `50-cloud-init.yaml` from
   `network_data.json`. Result on a dual-homed node: `ens3` via Ext-Net DHCP
   **and** `ens4` static **with `default via <private-gw>`**. Two defaults
   from this file alone.
3. cloud-init **config stage** writes our files (`99-...yaml` with the
   private static IP and *no* default on public nodes / *with* default on
   private-only nodes; scrub script; service unit) and runs `runcmd`
   (`netplan generate` + `apply` converge the merge once).
4. On every boot, after `network-online.target`, the **oneshot service**
   verifies (IP present? routes as intended?) and, on public-attached nodes
   only, **deletes `default dev <private-iface>`** — the route our file
   cannot un-declare. On private-only nodes it fails loudly if the default
   is missing instead.

## 3. Problem 1 (solved): user-data delivery without DHCP

Old world (`ovh_cloud_project_instance`, no config-drive option): the guest
could only fetch `user_data` from the `169.254.169.254` metadata proxy, which
only exists if Neutron runs a DHCP agent on the subnet. So `dhcp = true` was
mandatory even though guests use static IPs — set `dhcp = false` and VMs
booted blank (`DataSourceNone`: no user, no key, no IP). Side effect: orphan
DHCP ports blocked subnet deletion (`409`).

New world (`openstack_compute_instance_v2`, `config_drive = true`):
`user_data`/`network_data` arrive on a virtual CD-ROM, no network needed.
`dhcp = false` is safe: no blank boots, no `409`. **But config-drive changed
how the slip of paper arrives, not what is written on it** — the gateway is
still in `network_data.json`, so `50-cloud-init.yaml` still carries the
private default on every boot.

## 4. Problem 2 (permanent): the stale private default

Packet walk on a dual-homed node with two defaults (private listed first):

```
you ──SYN──▶ ens3 (public IP)          # arrives fine
                │
     kernel picks first default ──▶ ens4 (private)
                │
     SYN-ACK, src=public IP, leaves via private port ──▶ Neutron drops it (spoofing)
                │
you ── ...waiting... ──▶ Connection timed out
```

* Dual-homed nodes must exit via **public**. One extra default via private =
  asymmetric routing = no SSH from the internet. Symptom is always **timeout**
  (not refused/denied — sshd, keys, and firewall are fine).
* Private-only nodes must exit via the **private gateway** (their only path;
  without it `curl https://get.rke2.io` fails). Their `50` and `99` agree,
  so they never need scrubbing — the service only verifies there.
* `enable_gateway_ip = false` would remove the gateway from `network_data`,
  but the kube-api LB with floating IP requires it. Rejected.
* Deleting `50-cloud-init.yaml` from `write_files` loses the race: cloud-init
  regenerates it in the network stage, after `write_files` run. Rejected.
* DHCP for the private NIC surrenders deterministic `cidrhost` addressing.
  Rejected.
* A first-boot-only `runcmd` (no service) works once, but a reboot re-applies
  netplan from files and resurrects the stale route. Hence a **service**, not
  just `runcmd`.

So the scrub is the thinnest correct layer: yaml declares intent, the oneshot
service deletes exactly one known-stale route family per boot.

## 5. History, with evidence

* **2026-09-16 — config-drive migration + bastion outage.** Migration fixed
  delivery; the bastion shipped with only `netplan apply` (no scrub) and went
  unreachable. Console-log `ci-info` (pre-service stage) showed the mechanism:
  `default via 10.0.20.1 dev ens4` **and** `default via 141.94.104.1 dev
  ens3`. Packet in via `ens3`, reply out via `ens4`, dropped. Fix: bastion
  got the same script + service as cluster nodes.
* **2026-09-17 — simplification attempt, second outage, restore.**
  Premise: `network: {config: disabled}` in user-data stops cloud-init from
  writing `50-cloud-init.yaml`. Applied — bastion timed out; `disabled` was
  ignored (plus a `schema.py` WARNING). Conclusion: `disabled` does not work
  on this stack; scrub restored, `disabled` dropped, shared `public_iface`
  kept.
* **2026-09-17 evening — hotplug resurrection → timer.** The scrubbed bastion
  answered the probe, then went dead minutes later with no reboot — netplan
  re-applied without reboot (cloud-init `hotplugd` on Neutron port updates)
  brought the stale default back. Fix: `infrafactory-ovh-private-netplan.timer`
  (2 min interval); worst case now ~2 min of asymmetry after a hotplug event.
* **2026-09-17 evening — DNS race.** Private-only nodes' sole DNS comes from
  the `99` file, but first-boot `netplan apply` raced resolved readiness.
  Fix: `dns_ok()` re-apply in the verify script + `FallbackDNS=213.186.33.99`
  drop-in + `systemctl restart systemd-resolved` in runcmd. Durable
  alternative for later: `dns_nameservers` on the Neutron subnet.
* **2026-09-17 ~23:41 — cluster green.** Both nodes Ready
  (v1.36.4+rke2r1); kubeconfig fetched. Fresh `destroy` + `apply` from zero
  validated the pipeline.
* **Destroy post-mortem (same evening).** A `destroy` hit subnet-delete
  `409` with zero ports visible — transient Neutron IPAM lag, re-run passed.
  Then an OVH API `500` on network delete completed async (retry showed
  success). Lesson: OVH `500`s were all transient; retry before
  investigating.

## 6. Current architecture (file map)

* `providers/shared/cloud-init/{default,k3s,rke2}/network_config.cfg.tftpl` —
  single-NIC base + optional `public_iface` DHCP block.
* `providers/ovh/clusters/templates.tf` — cluster nodes: `99` via shared
  template, scrub trio, service `runcmd`. No `network.config` key.
* `providers/ovh/clusters/bastion.tf` — embedded bastion: same trio for
  `ens4` (+ sshd `PermitOpen` verify, `ip_forward=0`). Migrating to the
  standalone `providers/ovh/bastion/` module (hot-attach ports, N clusters).
* `providers/ovh/clusters/network.tf` — `dhcp = false`, gateway iff LB, SGs,
  LB/FIP.
* `providers/ovh/clusters/main.tf` — Nova instances, `config_drive = true`,
  `ignore_changes = [user_data]`.
* Orphan-port cleanup (`scripts/ovh-purge-port.sh`) — **deleted
  2026-09-17.** With `dhcp = false` that port class cannot exist. If a `409`
  ever recurs (detached port), delete by hand: `openstack port list
  --network <net-id>` then `openstack port delete <port-id>`.

## 7. Diagnose cheat sheet

| Symptom | Meaning | Look at |
|---|---|---|
| `:22` **timeout** | packets dropped/routed wrong (SG or asymmetric routing), never auth | `ip -4 route` (two defaults?), `cat /etc/netplan/*.yaml`, `journalctl -u infrafactory-ovh-private-netplan`, `openstack console log show` (`ci-info` tables), `openstack port list --server` |
| `:22` refused/reset | sshd down or nothing listening | guest `systemctl status ssh`, cloud-init errors |
| auth denied | network fine, key/user wrong | `authorized_keys`, `cloud-init.log`, key in `env/OVH/<env>/.key.*` |
| blank VM (no user) | user-data never delivered (pre-config-drive era) | datasource logs; gone since `config_drive = true` |
| destroy `409` ports | transient Neutron IPAM lag (re-run passes) | retry before investigating |
| `port show` empty SGs | display quirk, not evidence | trust `tofu state` associates + actual reachability instead |

## 8. Open questions

1. `enable_gateway_ip` is coupled to `lb_enabled`: LB off = no gateway =
   private-only nodes routeless. Deliberate for now; revisit if a
   gateway-less topology is ever needed.
2. Subnet-level `dns_nameservers` so `50-cloud-init.yaml` carries DNS from
   the network stage (removes first-boot DNS dependence on our files).
3. Readiness wait (poll) before nodes boot during gateway churn, or move
   node package install after convergence checks.

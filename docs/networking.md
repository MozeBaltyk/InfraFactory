# Networking & Endpoint Terminology

This document defines address/endpoint terminology and the per-provider
network topologies. Architectural rules are in `docs/architecture.md`; the
canonical provider interface is in `docs/provider-contract.md`.

## Endpoint Semantics

Never conflate these four roles:

```text
node_address        — identity of a node (e.g. private IP used as inventory host)
bootstrap_endpoint  — deterministic per-node access during bootstrap
management_endpoint — stable day-2 management access (Talos)
kubernetes_endpoint — stable Kubernetes API endpoint
```

For Talos specifically:

```text
bootstrap_endpoint  = deterministic per-node Talos API access
management_endpoint = stable day-2 Talos API endpoint
kubernetes_endpoint = stable Kubernetes API endpoint
```

Rules:

- A temporary SSH tunnel MUST NOT become the final user-facing endpoint.
- The Kubernetes API endpoint resolution order (OVH) is:
  `LB floating IP > literal value > DNS name > first master public IP > first
  master private IP`.

## Per-Provider Topologies

### Azure

- Networking is fully ARM-managed: no cloud-init network config.
- Every VM gets a `Standard` SKU static public IP.
- Private IPs are dynamically allocated by Azure.
- Azure Private DNS Zone + A records linked to the VNet.
- Subnet derived from `network.cidr` via `cidrsubnet()`.
- NSG rules configurable (SSH 22, K8s API 6443 defaults).
- Ansible inventory is public-IP based.

### Libvirt

- Connection: local `qemu:///system` or remote `qemu+ssh://`.
- Network mode: `nat`, `route`, or `bridge` (validated with mode-specific
  requirements).
- IP type: `dhcp` or `static`.
- Optional per-role `ip_addresses` / `mac_addresses`.
- Gateway: optional, auto-derived from CIDR for nat/route; required for
  bridge+static.
- DNS: `network.extra_dns` (default `8.8.8.8` / `8.8.4.4`); libvirt gateway
  prepended in nat/route.
- No public IP model.
- Ansible inventory uses the operator endpoint (coalesces static IP, runtime
  IP, FQDN).

### OVH

- Private network: `network.private.cidr` (required) + optional
  `network.private.vlan_id` (default 0; range 0–4000).
- Deterministic private IPs computed from
  `cidrhost(local.private_cidr, offset)`.
- NIC topology:
  - **Normal mode**: masters/workers are public (`ens3`) + private (`ens4`).
  - **Dedicated-bastion mode** (`ssh_jump_enabled=true`): one public+private
    bastion; masters/workers are private-only (`ens3`) with default route via
    the OVH subnet gateway and DNS `213.186.33.99`; standalone VMs remain
    dual-NIC.
- Subnet gateway IP (`enable_gateway_ip`) is set to `local.lb_enabled` —
  only reserves a gateway IP when a load balancer is present.
- LB mode adds: managed gateway (`ovh_cloud_gateway`), floating IP
  (`ovh_cloud_floating_ip`), and the Octavia load balancer (TCP/6443
  listener, health monitor, master members).
- Security groups (k3s/rke2): cluster-owned OpenStack SG; jump mode uses a
  separate bastion SG (TCP/22 from operator CIDRs) plus a private cluster SG
  (TCP/22 only from bastion SG, east-west TCP except 22, UDP, ICMP,
  LB/backend TCP/6443).
- Ansible inventory: public-IP based normally; jump mode uses private-node
  IPs with transport in `ansible.cfg`.

## SSH Transport Modes

| Mode | Mechanics |
|---|---|
| Direct (default) | `ssh -o StrictHostKeyChecking=no -i env/<PROVIDER>/<env>/.key.private <user>@<public-ip>` |
| OVH jump (bastion) | Self-contained `ProxyCommand` in `ansible.cfg` / output commands: `ssh -W %h:%p -q -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i <key> <user>@<bastion-ip>`. ProxyJump is NOT used: OpenSSH does not forward command-line `-i`/`-o` to the jump connection, so fresh host keys fail strict verification. |

Host-key verification is deliberately disabled for OVH jump mode:
connections trust the operator network and OVH SG/ingress controls instead of
a TOFU host-key anchor.

End-to-end operation of the OVH dedicated-bastion mode (configure → deploy →
connect → operate → replace → recover → destroy) is documented in
`docs/lifecycle.md` → "OVH Dedicated-Bastion Workflow".

## DNS Notes

- OVH private nodes use static DNS `213.186.33.99` (OVH public DNS) injected
  via the private-NIC netplan overlay; the overlay netplan is applied when the
  static DNS is not already in effect.
- OVH DHCP-served DNS (subnet default resolver) can be empty; do not rely on
  it for cluster bootstrap.
- Libvirt uses `network.extra_dns` + gateway for resolution.
- Azure uses Azure-managed DNS / Private DNS Zone.

## Generated Artifacts

All artifacts (hosts.ini, ansible.cfg, ssh keys, token, kubeconfig,
talosconfig) belong under `env/<PROVIDER>/<environment>/`. See
`docs/architecture.md` for the artifact rule.
# TO0 — Contract, isolation, and decisions — pending

## Goal

Freeze the Talos-on-OVH contract before implementation. Talos remains absent
from OVH until every decision below has one selected design, documented
evidence, and a rollback path.

## Scope

Non-regression and isolation invariants:

- Existing OVH K3s, RKE2, and `default` VM workspaces are never test subjects.
- `cloud_init_selected != "talos"` preserves resource addresses, inputs,
  rendered user-data, NIC order, security rules, outputs, and artifacts.
- Talos resources are additive and conditional; no imports, state moves,
  targeted state edits, or replacement of an existing installation.
- Talos uses the normalized node and endpoint model from
  `../architectures/00-general.md`: private node address, deterministic
  per-node bootstrap endpoint, stable management endpoint, and stable
  Kubernetes endpoint stay distinct.
- Talos bypasses cloud-init, SSH node access, and Ansible. Unsupported mixed
  standalone VMs, storage injection, and cloud-init inputs fail at plan time.
- Secrets and generated `kubeconfig`/`talosconfig` remain under
  `env/OVH/<workspace>/`; temporary bootstrap endpoints never enter the final
  `talosconfig`.

Resolve these decision gates, recording lasting choices in `../decisions/`:

1. **Image ownership:** operator-preloaded, versioned regional Glance image or
   OpenTofu-owned Image Factory download/upload. Define version, checksum,
   visibility, regional lifecycle, and deletion ownership.
2. **Network boot:** prove OpenStack-image config-drive networking with OVH
   `dhcp = false`, choose Talos-only fixed-address DHCP, or generate static
   machine configuration before Nova boot. Do not assume cloud-init behavior.
3. **Bootstrap transport:** deterministic per-node TCP/50000 access through
   the standalone bastion, VPN, or another private transport. Define tunnel
   ownership, credentials, unique local ports, readiness, cleanup, and failure
   behavior.
4. **Install disk:** derive from verified image/flavor evidence or require an
   explicit validated input; never infer `/dev/sda` or `/dev/vda`.
5. **Management exposure:** public CIDR-restricted LB TCP/50000, private VPN,
   or another stable endpoint. Define SG source, TLS path, DNS ownership, and
   whether TCP/6443 and TCP/50000 share the LB address.

## Gate TO-G0 — go/no-go

**Go:** all five decisions are explicit, compatible with
`docs/00-repo-contract.md` and `../specs/ovh/provider.md`, and retain every
isolation invariant. **No-go:** any design needs an existing workspace,
unconditional OVH behavior, guessed disk/interface data, state surgery, or a
temporary endpoint in a user-facing artifact. Return to this phase; create no
cloud resources.

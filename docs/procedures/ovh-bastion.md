# OVH standalone bastion — operator how-to

One mutualized bastion (`providers/ovh/bastion/`) serves many clusters
(`providers/ovh/clusters/`). Rationale lives in
`../decisions/2026-09-18-ovh-bastion-split.md`; live validation steps in
`../plan/phase-05-live.md`. This file is the day-to-day procedure.

## Two states, two workspaces — never one

Bastion and clusters are separate root modules, so they keep separate
states by construction. A workspace is a namespace *inside* one
configuration; it cannot span two. Merging them into one configuration
would re-couple what the split removed (single blast radius, gateway/LB
churn on bastion replacement).

| Stack | Directory | Workspace var | Tfvars |
|---|---|---|---|
| Bastion | `providers/ovh/bastion/` | `BASTION_ENV` (default `bastion`) | `env/OVH/<BASTION_ENV>.tfvars` |
| Cluster | `providers/ovh/clusters/` | `ENV` (one per cluster) | `env/OVH/<ENV>.tfvars` |

```bash
just ovh::bastion-validate
BASTION_ENV=bastion just ovh::bastion-plan
ENV=<cluster> just ovh::plan
```

There is deliberately no `terraform_remote_state` and no shared backend:
only a public-IP string flows bastion → cluster, only public keys flow
cluster → bastion.

## How a cluster is pointed at its bastion

In `env/OVH/<cluster>.tfvars`:

```hcl
bastion = { public_ip = "203.0.113.10" }  # required for Kubernetes; omit only for VM-only deployments
```

The rest is convention, not wiring:

* Bastion username **must equal** `cluster.username` (single bastion user;
  the cluster's ProxyCommand ssh's as its own user).
* The bastion's private IP on your network is the shared reserved address
  (last usable host of `network.private.cidr`), computed independently by
  both stacks via `providers/shared/modules/ipam` — no shared state.
* Jump mode additionally requires an enabled load balancer with
  `network.kube_api.endpoint = "lb_ip"` (guarded by
  `validate_ssh_jump_topology`).

Warning: Kubernetes on OVH is jump-only (see
`../decisions/2026-09-18-ovh-jump-only.md`). The old
`network.kube_api.load_balancer.ssh_jump_enabled` flag no longer exists
and is **silently ignored**, and a Kubernetes workspace without
`bastion.public_ip` fails fast — there is no public topology for k3s/rke2
anymore.

## Birth a bastion, attach clusters

1. Birth empty (`clusters = {}` in the bastion tfvars), `apply`, check SSH
   with the admin key. No `PermitOpen` restriction exists yet — an empty
   allowlist would lock out forwarding.
2. Deploy (or keep) the cluster network, then register the cluster in the
   bastion tfvars (`env/OVH/tfvars.bastion.example` is the template):

   ```hcl
   clusters = {
     <cluster> = {
       cidr            = "10.0.20.0/24"  # must match the cluster tfvars
       vlan_id         = 20              # distinguishes networks per region
       masters         = 1               # must match (sizes PermitOpen)
       workers         = 1               # must match
       public_key_file = "../../env/OVH/<cluster>/.key.pub"
     }
   }
   ```

   `apply` hot-attaches one NIC (`ens4`, `ens5`, … in sorted name order);
   the VM and its public IP are untouched.
3. Set `bastion.public_ip` in the cluster tfvars and `apply` the cluster.
   Day-2 convergence (keys, netplan, `PermitOpen`) is Ansible-owned with
   `ignore_changes = [user_data]` — never a replacement.

## One bastion, several clusters

Add one `clusters` entry per cluster; each cluster's tfvars points at the
same `public_ip`. Constraints, all by design:

* Same region — one bastion is regional (`var.bastion.region`).
* Same username on every sharing cluster (single bastion user).
* `cidr`/`vlan_id` must match each cluster's network (how the bastion
  discovers the private network to attach).
* `masters`/`workers` counts kept in sync with each cluster's tfvars
  (they size the `PermitOpen` allowlist; node growth past the reserved IP
  is guarded on both sides).
* Detach by emptying the entry and applying *before* destroying the
  bastion, otherwise ports strand (`destroy-all`).

## N-cluster runbook (same jumphost, different ENVs)

One bastion workspace, one workspace per cluster. End to end:

1. Birth the bastion once: `clusters = {}` in `env/OVH/<BASTION_ENV>.tfvars`,
   `BASTION_ENV=<bastion> just ovh::bastion-deploy`, SSH-check with the
   admin key.
2. Per cluster `<env>` (repeat for each):
   1. Create `env/OVH/<env>.tfvars` with its own `network.private.cidr`
      and `vlan_id`, same `cluster.region` and `cluster.username` as the
      bastion. Deploy keys + network first (targeted apply), so the
      private network exists.
   2. Append the entry to the bastion tfvars and
      `BASTION_ENV=<bastion> just ovh::bastion-deploy`. One port + one
      hot-attach; the VM, its public IP, and all previously attached
      clusters are untouched. Several entries may be registered before
      this single apply.
   3. Set `bastion = { public_ip = "<same-ip>" }` in `env/OVH/<env>.tfvars`
      and `ENV=<env> just ovh::deploy`.
   4. Converge the bastion (`just ovh::bastion::converge KEY`) so keys and
      `PermitOpen` cover the new nodes; verify jump SSH to a private node.
3. Recheck after every attach: `tofu output` private IPs, `PermitOpen`
   covers all clusters' nodes, previously attached clusters still jump
   cleanly.

Conventions (not enforced in code — verified by inspection, no
cross-stack check exists):

* Key the `clusters` entry exactly like the cluster's `ENV`/workspace
  name. The key is bastion-local (port names, netplan filenames), but it
  is the only thread tracing NIC → cluster.
* Treat keys as immutable once attached: NIC order (`ens4`, `ens5`, …)
  follows *sorted key* order, so renaming a key renumbers interfaces.
* `vlan_id` values must be distinct per cluster per region: discovery
  requires *exactly one* network per (vlan, region), and a duplicate
  fails the precondition instead of attaching wrong.

## Migrate an embedded-bastion cluster

Toggling jump on an existing cluster replaces masters/workers: back up
etcd/workloads, schedule downtime, save/review the full authenticated
plan first. `just replace` refuses the first K3s/RKE2 controller — recover
it only through a verified etcd snapshot and the distribution restore
procedure. See `../plan/phase-03-decoupling.md` (state surgery) and the
`ssh_jump_enabled` warning above.

# OVH cluster deployment — operator how-to

Consolidated end-to-end procedure for deploying a Kubernetes cluster on OVH
Public Cloud. Kubernetes on OVH is **jump-only**: masters/workers are
private-only and reachable solely through a standalone bastion. The bastion's
own lifecycle (birth, multi-cluster attach, teardown) lives in
[`ovh-bastion.md`](ovh-bastion.md); this file is the cluster-side runbook and
the one-stop end-to-end flow.

Target state: [`../specs/ovh/provider.md`](../specs/ovh/provider.md).
Why jump-only: [`../decisions/2026-09-18-ovh-jump-only.md`](../decisions/2026-09-18-ovh-jump-only.md).
Why the bastion is a separate stack:
[`../decisions/2026-09-18-ovh-bastion-split.md`](../decisions/2026-09-18-ovh-bastion-split.md).

## The two stacks

| Stack | Directory | Workspace var | Tfvars |
|---|---|---|---|
| Bastion | `providers/ovh/bastion/` | `BASTION_ENV` (default `bastion`) | `env/OVH/<BASTION_ENV>.tfvars` |
| Cluster | `providers/ovh/clusters/` | `ENV` (one per cluster) | `env/OVH/<ENV>.tfvars` |

Independent states, no `terraform_remote_state`, no shared backend. Only a
public-IP string flows bastion → cluster (`bastion.public_ip`); only public
keys flow cluster → bastion (the `clusters` map key == cluster workspace name).

## Prerequisites

1. **OVH API token with the load-balancer stack rights.** It must cover compute
   and network *and* gateway / floating IP / load balancer. A token scoped to
   compute+network only fails at `just ovh::deploy` with
   `403 Client::Forbidden "This call has not been granted"` on
   `ovh_cloud_gateway` / `ovh_cloud_floating_ip`. Export
   `OVH_APPLICATION_KEY`/`OVH_APPLICATION_SECRET`/`OVH_CONSUMER_KEY`, or put
   them in the tfvars.
2. **OpenStack auth** for the same project (`OS_*`, or
   `env/OVH/<ENV>.openrc` — the recipes auto-source it).
3. Tools: `tofu`, `just`, `ansible`, and `jq` (jq only for the bastion converge
   recipe).

## End-to-end

### 0. Birth the bastion (once per region)

See [`ovh-bastion.md`](ovh-bastion.md). In short: `env/OVH/<BASTION_ENV>.tfvars`
with `clusters = {}`, then `BASTION_ENV=<b> just ovh::bastion-deploy`, and
verify SSH with the admin key.

### 1. Write the cluster tfvars

`env/OVH/<env>.tfvars` (template: `env/OVH/tfvars.example`). Minimum for a
jump-only cluster:

```hcl
cluster = {
  id                  = "mycluster"
  region              = "GRA11"
  username            = "localadmin"      # MUST equal the bastion username
  cloud_init_selected = "rke2"            # or k3s
}

infra = {
  masters = { count = 1 }
  workers = { count = 1 }
}

bastion = {
  public_ip = "203.0.113.10"              # required for Kubernetes; omit only for VM-only
}

network = {
  private = {
    cidr    = "10.0.30.0/24"              # unique (cidr, vlan) per cluster in the region
    vlan_id = 30
  }
  kube_api = {
    endpoint      = "lb_ip"               # or "dns" + dns.name
    ingress_cidrs = ["203.0.113.0/24"]    # at least one explicit entry (caller IP auto-added)
    load_balancer = {
      enabled       = true                # required for Kubernetes
      flavor        = "small"
      gateway_model = "s"
    }
  }
}
```

### 2. Bootstrap (private network + keys only)

```bash
ENV=<env> just ovh::bootstrap
```

Creates the private network/subnet and the cluster SSH keypair
(`env/OVH/<env>/.key.{pub,private}` + `.token`). The network must exist before
the bastion can discover and attach to it.

### 3. Register + attach the bastion

Append to `env/OVH/<BASTION_ENV>.tfvars`:

```hcl
clusters = {
  <env> = {
    cidr    = "10.0.30.0/24"              # must match the cluster tfvars
    vlan_id = 30                          # must match (per-region network discovery)
    masters = 1                           # must match (sizes PermitOpen)
    workers = 1                           # must match
    # public_key_file omitted → defaults to env/OVH/<env>/.key.pub
  }
}
```

```bash
BASTION_ENV=<b> just ovh::bastion-deploy   # hot-attaches one private NIC (reserved IP)
```

### 4. Converge the bastion (merge cluster key + PermitOpen)

```bash
just ovh::bastion::converge <ABSOLUTE-path-to-bastion-admin-key>
```

e.g. `just ovh::bastion::converge /home/you/InfraFactory/env/OVH/bastion/.key.private`

> ⚠️ `KEY` is resolved **relative to `providers/ovh/bastion/`**, not the repo
> root — a repo-root-relative path like `env/OVH/bastion/.key.private` fails
> with `no such identity`. Pass an absolute path.

This step is **required between attach and deploy**: the attach only changes
Terraform state; the running bastion still has birth-time keys, and the
cluster's Ansible jump fails closed until the cluster pubkey is merged.

### 5. Deploy

```bash
ENV=<env> just ovh::deploy
```

Boots private-only masters/workers (cloud-init k3s/rke2), creates the gateway +
floating IP + Octavia LB (TCP 6443/80/443 → masters), then runs Ansible over the
bastion jump (cloud-init check → TLS SAN reconcile → kubeconfig fetch). First
boot is ~5–15 min.

### 6. Validate

```bash
PROVIDER=OVH ENV=<env> just check        # kubectl get nodes via env/OVH/<env>/kubeconfig
```

Jump-SSH to a private node using the command in the `cluster_nodes` output.

### Destroy

```bash
ENV=<env> just ovh::destroy
```

Detach from the bastion **before** destroying the bastion itself (empty the
`clusters` entry + `bastion-deploy`), otherwise ports strand — see
[`ovh-bastion.md`](ovh-bastion.md). On a transient `409`/`500` during destroy,
just retry (see [`../troubleshooting/ovh-destroy.md`](../troubleshooting/ovh-destroy.md)).

## Artifacts

- Cluster `env/OVH/<env>/`: `.key.{pub,private}`, `.token`, `hosts.ini`,
  `ansible.cfg` (self-contained jump ProxyCommand), `kubeconfig`.
- Bastion `env/OVH/<BASTION_ENV>/`: `.key.{pub,private}`, `.token`. The
  bastion's `.token` is an unused byproduct of the shared key module (a bastion
  has no cluster token); tracked for removal.

## Gotchas

- **`403 … not been granted`** on `ovh_cloud_gateway`/`ovh_cloud_floating_ip` →
  OVH token lacks gateway/FIP/LB rights (prerequisite 1).
- **converge `KEY`** must be an absolute path (step 4).
- **Scaling a cluster**: after changing `masters`/`workers`, also sync the
  bastion `clusters[]` counts and re-run `converge`, or `PermitOpen` won't cover
  the new node IPs (`Connection closed by UNKNOWN port 65535`) — see
  [`ovh-bastion.md`](ovh-bastion.md).
- **First-boot DNS/apt** on private nodes:
  [`../troubleshooting/ovh-cloud-init-dns-race.md`](../troubleshooting/ovh-cloud-init-dns-race.md).
- **Private nodes have no internet at all** (`check_cloudinit` tainted, all
  nodes `cloud-init error` + no k8s service): gateway SNAT port DOWN →
  [`../troubleshooting/ovh-gateway-snat-down.md`](../troubleshooting/ovh-gateway-snat-down.md).

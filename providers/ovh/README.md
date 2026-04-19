# OVH provider findings

This document explains the current OVH implementation in this repository, the architecture produced by `just deploy`, and the main OVH-specific behaviors that are not obvious when only reading the variables.

## Scope

This README describes the current behavior implemented in:

- `providers/ovh/main.tf`
- `providers/ovh/networks.tf`
- `providers/ovh/templates.tf`
- `providers/ovh/output.tf`
- `providers/ovh/justfile`
- `providers/ovh/floating_ip_cleanup.py`

It is intentionally focused on **how this repository currently works with OVH**, not on all OVH capabilities in general.

---

## What `PROVIDER=OVH ENV=<env> just deploy` does

From the repository root, the generic `just deploy` flow delegates to `providers/ovh/justfile`.

The OVH deploy flow does the following:

1. `tofu init`
2. select or create the OpenTofu workspace matching `ENV`
3. apply `env/OVH/<ENV>.tfvars`

The OVH provider also exposes extra helper flows:

- `just ovh::capture-floating-ip`
- `just ovh::cleanup-floating-ip`
- `just ovh::destroy-with-cleanup`

Those helpers exist because OVH load balancer floating IP cleanup is not always fully handled by destroy alone.

---

## High-level architecture created on OVH

Depending on the tfvars, an OVH deployment creates:

### Local artifacts

Under `env/OVH/<workspace>/`:

- `.key.private`
- `.key.pub`
- `.token`
- `ansible.cfg`
- `hosts.ini`
- `kubeconfig` for `k3s` or `rke2`
- optionally `.ovh-floating-ip.json` during destroy/cleanup workflows

### OVH cloud resources

- one OVH SSH key resource
- `N` master instances
- `N` worker instances
- optionally one private network
- optionally one private subnet
- optionally one gateway
- optionally one OVH load balancer for the Kubernetes API
- optionally one floating IP created by the load balancer

Important current behavior:

- private networking and the kube API load balancer are currently coupled
- when `network.cidr` is set, the provider creates the private network, subnet, gateway, and kube API load balancer together
- there is no separate toggle today for "private network yes, load balancer no"

### Bootstrap and post-bootstrap actions

- inject shared cloud-init into each node
- wait for SSH readiness on public IPs
- wait for `cloud-init status --wait`
- fetch kubeconfig from the first master over SSH
- rewrite kubeconfig so it points to the public Kubernetes API endpoint
- when using a private-network load balancer in `lb_ip` mode, reconcile TLS SANs on masters after the load balancer endpoint exists

---

## Network model used by this Terraform

The current OVH design uses **public IPs for operations** and **private IPs for cluster internals**.

### Public side

Every instance is created with:

- `public = true`

This means each master and worker gets a public IPv4 address. That public IP is used for:

- SSH access
- waiting for cloud-init completion
- generated Ansible inventory
- kubeconfig retrieval from the first master

In other words, this implementation does **not** currently switch Ansible or SSH to the private network.

### Private side

When `network.cidr` is set, Terraform also creates:

- an OVH private network
- a subnet on that private network
- a gateway
- a Kubernetes API load balancer attached to that private network

That private network is used for:

- master-to-master join traffic
- worker-to-cluster join traffic
- load balancer backend membership on TCP `6443`
- stable internal addressing of cluster nodes

### Resulting architecture

With private networking enabled, the resulting shape is:

```text
operator
  |
  | SSH / Ansible / kubeconfig fetch
  v
public IP of each node

masters/workers
  |
  | cluster internal traffic
  v
OVH private network + subnet
  |
  | backend members: master private IPs:6443
  v
OVH load balancer + floating IP
  |
  | public Kubernetes API endpoint
  v
kubectl
```

So the OVH architecture is intentionally mixed:

- **public node IPs** for management access
- **private node IPs** for cluster communication
- **one public kube-api endpoint** via OVH load balancer floating IP, or a DNS name chosen as the advertised endpoint if configured outside Terraform

---

## Why we map private IPs with an offset instead of relying on DHCP

This is one of the most important OVH-specific implementation details.

### Short answer

Even though the OVH subnet enables DHCP, this Terraform does **not** rely on DHCP to choose node private addresses because the cluster bootstrap requires **deterministic, Terraform-known IPs**.

### What the code does

The subnet is created with DHCP enabled:

- `providers/ovh/networks.tf`

But each instance still receives an explicit private IP through Terraform:

- masters: `providers/ovh/main.tf`
- workers: `providers/ovh/main.tf`

Those IPs are computed from the configured CIDR using `cidrhost(...)` and a host offset.

### Why DHCP alone is not enough here

This implementation needs the private IPs **before** the cluster is fully ready because those addresses are reused in multiple places:

1. **Cluster join endpoint**
   - the first master private IP becomes the join target for additional masters and workers
2. **Kubernetes node config**
   - cloud-init writes `node-ip` and, for masters, `advertise-address`
3. **Load balancer members**
   - the OVH load balancer backend pool is built from the masters' private IPs
4. **Predictable bootstrap behavior**
   - Terraform and cloud-init can reference the same addresses consistently during apply

If DHCP were left to assign node addresses dynamically, Terraform would not have a stable, plan-time mapping for:

- which private IP belongs to which node
- which IP to use as the first master join target
- which private IPs to register as load balancer members

So DHCP may exist on the subnet, but **this cluster design behaves as statically addressed from Terraform's point of view**.

### Why there is an offset

The current code uses this rule:

- start at host offset `10` for CIDRs with prefix `<= 28`
- start at host offset `2` for smaller/tighter ranges

Practical interpretation:

- on normal subnets, the implementation leaves the very first host addresses unused
- on small subnets, it starts earlier to avoid wasting scarce addresses

### Why start at `.10` instead of letting DHCP distribute `.2`, `.3`, `.4`, etc.?

Because the goal is not just "get any valid IP". The goal is:

- deterministic node-to-IP mapping
- reproducible backend membership
- predictable join endpoint selection
- stable internal addresses across repeated applies in the same workspace

The exact choice of `10` is an implementation decision, not a documented OVH platform requirement. The code makes the behavior clear, but it does not currently explain why `10` was preferred over another low number such as `5`.

The best current explanation is:

- leave some low addresses free on regular subnets
- still keep room to fit all nodes on tiny subnets by falling back to `2`

So the important point is not the number `10` itself. The important point is that **private node IPs are intentionally pre-assigned, not dynamically discovered from DHCP**.

---

## Why DHCP is still enabled if private IPs are explicit

The subnet is created with DHCP enabled, but node IPs are still pinned explicitly.

That means DHCP is not the source of truth for node addressing in this implementation.

Today, DHCP is effectively just part of the subnet configuration, while the actual node private addresses are decided by Terraform. In practice:

- Terraform chooses the node IPs
- cloud-init and Kubernetes consume those chosen IPs
- the load balancer references those same chosen IPs

This is why "let DHCP distribute the IPs" is not compatible with the current bootstrap and load balancer design.

---

## How masters and workers join the cluster

The OVH provider keeps a split behavior:

- SSH and inventory use **public IPs**
- cluster join uses the **first master private IP** when private networking is enabled

That means:

- the operator reaches nodes through public IPs
- nodes reach the control plane through the private network

For workers, the first master endpoint passed into cloud-init is:

- the private join endpoint when private networking exists
- otherwise the first master public IP

This is the key reason the private IP mapping must be known in advance.

Important caveat for multi-master:

- the current implementation explicitly requires `network.cidr` when `infra.masters.count > 1`
- secondary masters rely on the private join path
- a public-IP fallback is implemented for workers, but not as the normal multi-master path

---

## Kubernetes API exposure on OVH

When `network.cidr` is configured, OVH creates a dedicated load balancer for the Kubernetes API.

### Current behavior

- listener on TCP `6443`
- backend pool members are the master private IPs
- a floating IP is created on the load balancer
- the public kube API endpoint prefers:
  1. DNS name when `kube_api_endpoint_mode = "dns"`
  2. load balancer floating IP
  3. load balancer VIP
  4. first master public IP as fallback

Important clarification:

- `kube_api_endpoint_mode = "dns"` does not disable load balancer creation
- it only changes which endpoint is preferred and advertised in templates and kubeconfig
- the DNS record itself is not created or managed by this Terraform and must exist outside this provider

### Why post-bootstrap TLS SAN reconciliation exists

For `k3s` and `rke2`, the load balancer endpoint may only be fully known after creation.

Because of that, the OVH provider runs a post-bootstrap reconciliation step that:

- adds the load balancer endpoint to `tls-san`
- removes the old serving certificate
- restarts the Kubernetes service
- waits again for API readiness

This is OVH-specific glue to make the final public API endpoint usable with the certificates generated on the masters.

---

## Why `floating_ip_cleanup.py` exists

The script exists because **destroy may leave the OVH load balancer floating IP orphaned**.

### Problem being solved

The load balancer requests a floating IP through:

- `floating_ip_create`

That floating IP is attached to the OVH load balancer lifecycle, but in practice it may survive after `tofu destroy` and remain billable or clutter the project.

### What the script does

`providers/ovh/floating_ip_cleanup.py` has two commands:

#### `capture`

- read Terraform state
- locate `ovh_cloud_project_loadbalancer.kube_api`
- extract the exact floating IP id and address
- save them to `env/OVH/<workspace>/.ovh-floating-ip.json`

#### `cleanup`

- read OVH API credentials from the tfvars
- verify the captured floating IP belongs to the same OVH project
- call the OVH API directly to delete that exact floating IP
- optionally try detach first if OVH reports it is still attached

### Why not just delete "any floating IP"?

The script is intentionally conservative.

It captures the **exact** floating IP created for the Kubernetes API load balancer and cleans up only that one. This reduces the risk of deleting unrelated floating IPs that may exist in the same OVH project.

### How it fits the workflow

Recommended destroy flow when a load balancer floating IP exists:

1. capture the floating IP from state
2. run destroy
3. call cleanup against the captured IP

That is exactly what `just ovh::destroy-with-cleanup` automates.

---

## Why inventory stays on public IPs

The generated `hosts.ini` uses:

- `controller_ips = local.master_public_ips`
- `worker_ips = local.worker_public_ips`

So Ansible inventory does **not** currently use the private network.

This matches the current OVH operational model:

- private networking is for cluster internals
- public addressing is for operator access

This is also why the first master SSH endpoint and kubeconfig fetch use the public side.

---

## Cloud-init behavior on OVH

OVH reuses the shared cloud-init templates from `providers/shared/cloud-init/<type>/cloud_init.cfg.tftpl`.

These templates are used for:

- hostname and FQDN
- user creation and SSH key injection
- package installation
- `k3s` or `rke2` bootstrap/join
- optional `ansible-pull`

Important OVH detail:

- OVH does **not** currently use the shared `network_config_*.cfg` templates

Unlike libvirt, OVH networking is modeled directly in Terraform through instance network attachments and explicit private IP assignment.

---

## End state after a successful OVH deploy

After `PROVIDER=OVH ENV=<env> just deploy`, the user typically has:

- reachable OVH masters and optional workers
- public SSH access to every node
- optional private east-west cluster network
- optional public Kubernetes API endpoint via OVH load balancer floating IP, or via an externally managed DNS name when DNS mode is used
- a generated inventory in `env/OVH/<env>/hosts.ini`
- a generated kubeconfig in `env/OVH/<env>/kubeconfig`

Operationally, this means the repository gives:

- **public-IP-based operator access** for SSH, Ansible, and kubeconfig retrieval
- **cluster bootstrap** through private addresses when available
- **kubectl** through the load balancer public endpoint when available

---

## Current limitations and caveats

These findings reflect the current implementation and are important to keep in mind.

### 1. The private IP offset is explained by design needs, not yet by inline documentation

The code clearly shows **why deterministic private IPs are needed**, but the exact reason for choosing `10` as the normal offset is not yet documented in code comments.

### 2. DHCP is enabled, but private addressing is effectively static

So the OVH subnet is not operating like a pure DHCP-assigned node network in this implementation.

### 3. OVH inventory is public-IP based

Even when a private network exists, Ansible inventory remains on public IPs.

### 4. Private networking and the kube-api load balancer are currently coupled

When `network.cidr` is set, the current implementation creates the private network, subnet, gateway, and kube-api load balancer together.

### 5. Floating IP cleanup is an explicit lifecycle concern

The cleanup helper exists because OVH load balancer destroy behavior may leave a floating IP behind.

### 6. Example tfvars comments must stay aligned with the implementation

`env/OVH/tfvars.example` now reflects the current OVH provider behavior and should continue to stay aligned as the provider evolves.

---

## Summary

The OVH implementation in this repository is based on a clear architectural split:

- **public IPs** for operator access and generated inventory
- **deterministic private IPs** for cluster formation and load balancer backends
- **OVH load balancer + floating IP** for a stable public Kubernetes API endpoint

Because of that design:

- DHCP is not used as the source of truth for node addressing
- private IPs are mapped deterministically with an offset
- a dedicated cleanup script is needed to remove floating IPs that OVH destroy may leave behind

These are not arbitrary implementation details: they are direct consequences of how the current OVH bootstrap, networking, and API exposure model has been built.

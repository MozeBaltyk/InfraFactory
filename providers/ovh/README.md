# OVH provider findings

This document explains the current OVH implementation in this repository, the architecture produced by `just deploy`, and the main OVH-specific behaviors that are not obvious when only reading the variables.

## Scope

This README describes the current behavior implemented in:

- `providers/ovh/main.tf`
- `providers/ovh/network.tf`
- `providers/ovh/templates.tf`
- `providers/ovh/output.tf`
- `providers/ovh/ansible.tf`
- `providers/ovh/cleanup_gateway.py`

It is intentionally focused on **how this repository currently works with OVH**, not on all OVH capabilities in general.

---

## What `PROVIDER=OVH ENV=<env> just deploy` does

From the repository root, the generic `just deploy` flow delegates to `providers/ovh/justfile`.

The OVH deploy flow does the following:

1. `tofu init`
2. select or create the OpenTofu workspace matching `ENV`
3. apply `env/OVH/<ENV>.tfvars`

Destroy uses the standard `just destroy` recipe. A destroy-time provisioner on `null_resource.private_network_destroy_grace` invokes `cleanup_gateway.py` to remove the OVH gateway that the load balancer creates implicitly via `gateway_create` and that the OVH provider does not cascade-delete with the LB. The same script also removes the orphan floating IP allocated via `floating_ip_create`.

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

### OVH cloud resources

- one OVH SSH key resource
- 1 private network
- 1 private subnet on that private network
- `N` master instances
- `N` worker instances
- optionally one OVH load balancer for the Kubernetes API, which implicitly creates one gateway and one floating IP

Important current behavior:

- the private network and subnet are always created (the schema requires `network.private.cidr`)
- when `network.kube_api.load_balancer.enabled` is true, the load balancer is created. It uses OVH's `gateway_create` and `floating_ip_create` to allocate its own gateway and floating IP. Those two resources are owned by the load balancer lifecycle on the OVH side but are not cascade-deleted by the OVH provider, so destroy invokes `cleanup_gateway.py` to remove them.

### Bootstrap and post-bootstrap actions

- inject shared cloud-init into each node
- wait for SSH readiness on public IPs
- wait for `cloud-init status --wait` (via Ansible shared playbook)
- reconcile kube-apiserver TLS SAN on first master (via Ansible shared playbook)
- fetch kubeconfig from the first master (via Ansible shared playbook)
- rewrite kubeconfig so it points to the public Kubernetes API endpoint

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

When `network.private.cidr` is set, Terraform also creates:

- an OVH private network
- a subnet on that private network

When `network.kube_api.load_balancer.enabled` is true, Terraform also creates:

- a Kubernetes API load balancer attached to that private network, which transparently allocates a gateway and a floating IP through OVH's `gateway_create` and `floating_ip_create`

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

- the current implementation explicitly requires `network.private.cidr` when `infra.masters.count > 1`
- secondary masters rely on the private join path
- a public-IP fallback is implemented for workers, but not as the normal multi-master path

---

## Kubernetes API exposure on OVH

When `network.kube_api.load_balancer.enabled` is true, OVH creates a dedicated load balancer for the Kubernetes API.

### Current behavior

- listener on TCP `6443`
- backend pool members are the master private IPs
- a floating IP is created on the load balancer via `floating_ip_create`
- the public kube API endpoint resolves from `network.kube_api.endpoint`:
   1. **load balancer floating IP** — when `endpoint = "lb_ip"` and the LB has been created
   2. **literal value** — when `endpoint` is neither `"lb_ip"` nor `"dns"`, use it directly (e.g. an external IP or hostname)
   3. **DNS name** — when `endpoint = "dns"` and `dns.name` is set
   4. **first master public IP** — fallback when none of the above applies
   5. **first master private IP** — last resort if public IPs are not yet available

Important clarification:

- `endpoint = "dns"` does not disable load balancer creation
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

## Why `cleanup_gateway.py` exists

The script exists because **the OVH provider does not cascade-delete two resources that the load balancer creates implicitly**:

- the gateway created by `gateway_create`
- the floating IP created by `floating_ip_create`

### Problem being solved

The load balancer requests both through:

- `gateway_create`
- `floating_ip_create`

When the load balancer is destroyed, OVH leaves the gateway attached to the subnet (which blocks subnet deletion) and the floating IP remains allocated on the project (which keeps it billable).

### What the script does

`providers/ovh/cleanup_gateway.py` is invoked from `null_resource.private_network_destroy_grace` on destroy. It receives credentials, region, project, gateway name, and floating IP description through environment variables and:

- looks up the gateway by name and deletes it through the OVH API
- looks up the floating IP by description and deletes it through the OVH API
- waits for the OVH operations to reach a terminal state before returning

The script is conservative: it matches resources by the names and descriptions Terraform assigned, so it does not touch unrelated gateways or floating IPs in the same project.

### Runtime requirement

The script needs Python 3 and the `ovh` Python package. Install it once with:

```sh
pip install --user ovh
```

If the package is missing, destroy fails with a clear error message.

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

### Private NIC netplan injection

OVH instances always have two NICs: `ens3` (public) and `ens4` (private subnet).

The OVH subnet is created with `dhcp = true` and, once a load balancer exists on it, OVH's DHCP starts advertising the gateway IP as a default route on the private NIC. Without intervention, that route competes with the public NIC's default route and breaks inbound SSH on the public IP (asymmetric return path).

To prevent this, OVH renders the shared `providers/shared/cloud-init/<type>/network_config.cfg.tftpl` with DHCP enabled and `use-routes: false` / `use-dns: false`, then merges the result into the cloud-init `user_data` via:

- a `write_files` entry at `/etc/netplan/99-infrafactory-private.yaml`
- a `runcmd` entry `[netplan, apply]` that runs first, before any other cloud-init command

The private NIC therefore receives its IP via DHCP from the OpenStack port reservation Terraform set up, but ignores the DHCP-supplied default route and DNS.

The merge is performed in OVH's `templates.tf` using `yamldecode`/`yamlencode` so the shared `cloud_init.cfg.tftpl` itself is not modified and remains identical across providers.

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

### 4. Private networking and the kube-api load balancer are separate

The schema always requires `network.private.cidr`, so the private network and subnet are always created. Set `network.kube_api.load_balancer.enabled = true` to also create the kube-api load balancer (which transparently allocates a gateway and a floating IP on the OVH side).

### 5. Gateway and floating IP cleanup is an explicit lifecycle concern

The cleanup helper exists because OVH load balancer destroy behavior leaves both a gateway and a floating IP behind. `cleanup_gateway.py` deletes both on every destroy.

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

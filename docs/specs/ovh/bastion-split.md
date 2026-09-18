# Spec — OVH standalone bastion split (target state)

Normative target for the workstream tracked in `../../plan/` (P0–P6) and
motivated in `../../decisions/2026-09-18-ovh-bastion-split.md`. Implementation
details live in `../../architectures/ovh/`; operator steps in
`../../procedures/ovh-bastion.md`; OVH-wide provider norms in
`provider.md`. In case of conflict, this file wins on *what*; the others win on *why* (decisions), *how built* (architectures),
*how run* (procedures), *when* (plan).

## 1. Goal

One mutualized standalone SSH bastion serving many OVH clusters. The
cluster stack owns no bastion resources; it references the bastion by
value. OVH-only: libvirt/Azure keep their embedded model.

## 2. Non-goals

* No shared OpenTofu state and no `terraform_remote_state` between stacks.
* No routing, proxying, or NAT on the bastion (`ip_forward=0`); SSH-jump
  only (`AllowTcpForwarding local`), kube API via the LB.
* No automatic etcd recovery: replacing the first K3s/RKE2 controller stays
  blocked behind a verified snapshot + distribution restore procedure.

## 3. Components and states

| Stack | Module | Workspace | Inputs | State |
|---|---|---|---|---|
| Bastion | `providers/ovh/bastion/` | `BASTION_ENV` (default `bastion`) | `env/OVH/<BASTION_ENV>.tfvars` | own, singular |
| Cluster | `providers/ovh/clusters/` | `ENV` (one per cluster) | `env/OVH/<ENV>.tfvars` | own, per cluster |

A workspace never spans both configurations; fusing them would re-couple
blast radius and churn gateway/LB on bastion replacement.

## 4. Interfaces

Cluster → bastion (hand-typed, no backend link):

* `bastion = { public_ip }` in the cluster tfvars; `null`/omitted means
  public topology, unchanged from before the split.
* Convention: bastion username == cluster username.
* Jump mode additionally requires an enabled load balancer with
  `network.kube_api.endpoint = "lb_ip"` (guarded in-stack).

Bastion → cluster (hand-typed):

* `clusters.<name> = { cidr, vlan_id, masters, workers, public_key_file }`
  in the bastion tfvars; `masters`/`workers` match the cluster tfvars
  (they size `PermitOpen`).
* Reserved bastion address: last usable host of each cluster CIDR,
  computed independently by both stacks via
  `providers/shared/modules/ipam` (`bastion_ip`).
* `converge` output feeds the Ansible role (username, host, per-cluster
  NIC iface/address/prefix, `permit_open`, sshd test addresses, both key
  lists).

Only public keys flow cluster → bastion; only a public-IP string flows
bastion → cluster. Private keys never leave the operator laptop.

## 5. Network contract

* Bastion NIC order defines guest order: `ens3` public (DHCP) first, then
  one private NIC per attached cluster in sorted name order (`ens4`,
  `ens5`, …). Private NICs are hot-attached managed ports + interface
  attachments: attaching a cluster creates port + attach only, never a
  replacement.
* Jump-mode cluster nodes are private-only (single NIC); standalone
  `infra.vms` stay dual-NIC.
* Bastion SG: TCP/22 from explicit ingress CIDRs + operator IP. Cluster
  SG in jump mode: TCP/22 only from the bastion's reserved IP
  (`remote_ip_prefix`, never a cross-state group reference), east-west
  rules, LB backend TCP/6443 from the private CIDR. The LB exposes
  TCP/6443 only — never SSH.
* Guests use static netplan (`dhcp = false` subnets, config-drive
  user_data); a boot + periodic oneshot scrubs stale private default
  routes that would break inbound SSH asymmetrically.

## 6. Lifecycle and ownership

| Event | Owner | Mechanism |
|---|---|---|
| Birth (empty `clusters = {}`, admin key only) | OpenTofu, bastion stack | `apply` (readiness probe uses `probe_ssh_private_key_path`); no `PermitOpen` restriction yet |
| Attach cluster (port + NIC) | OpenTofu, bastion stack | `apply`; VM and public IP untouched |
| Point cluster at bastion | Operator edit + OpenTofu, cluster stack | set `bastion.public_ip`, `apply` |
| Day-2 keys / netplan / `PermitOpen` | Ansible (`bastion_converge` role via `just ovh::bastion::converge KEY`) | merge keys, apply netplan, verify + reload + re-verify sshd |
| Detach cluster | OpenTofu, bastion stack | empty the entry, `apply` before bastion destroy |
| Destroy | OpenTofu, per stack | `destroy-vm` (VM only, ports kept) or `destroy-all` |

`user_data` drift is ignored on both stacks; cloud-init is first-boot
data only. Toggling jump on an existing cluster replaces masters/workers:
etcd/workload backup, scheduled downtime, and a reviewed saved plan are
mandatory.

## 7. Sharing constraints

* One bastion is regional: all served clusters share its region.
* One bastion user: all served clusters share its username.
* `cidr`/`vlan_id` match each cluster's network (discovery key).
* Node allocation must never reach the reserved bastion IP (guarded on
  both stacks: widen the CIDR or reduce counts).

## 8. Acceptance

* G3: `validate` all providers; authenticated plan on a jump workspace
  shows bastion resources leaving the cluster state while VMs/gateway/LB
  are unchanged.
* G4: converge playbook `--syntax-check`, recipe parses, `validate` both
  root modules, no cloud contact.
* G5: bastion-first flow, full jump-mode cluster (private nodes, Ansible
  via bastion, kubeconfig), second-cluster attach (port + attach only),
  HA spot-check, `destroy-vm` redeploy, clean full destroy.
* G6: `providers/README` + test matrix, 2-cluster bastion example,
  `03-network.md` rewrite, procedures doc verified against P5, README
  roadmap checkbox.

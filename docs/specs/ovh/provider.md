# Spec — OVH provider (target state)

OVH-specific normative spec on top of `../baseline.md`. The bastion
split itself is specified in `bastion-split.md` (referenced, not
repeated here). Until P6 lands, `providers/README` still describes the
pre-split embedded model in places — on conflict, this file and
`bastion-split.md` win.

## 1. Credentials and region

* `ovh_endpoint`, `ovh_application_key`, `ovh_application_secret`,
  `ovh_consumer_key`, `ovh_project_service_name` — secrets from the
  environment, never committed.
* Kubernetes modes additionally require standard OpenStack auth (`OS_*`
  or `clouds.yaml`/`OS_CLOUD`) for security groups.
* One region per deployment via `cluster.region` (e.g. `GRA9`); one
  bastion serves only its region.

## 2. Private network and addresses

* The cluster always creates and owns its network:
  `ovh_cloud_project_network_private` + subnet from
  `network.private.cidr` (required) and `network.private.vlan_id`
  (optional, `0`–`4000`; distinct VLANs allow multiple clusters per
  region).
* Private IPs are deterministic via `providers/shared/modules/ipam`
  (masters, then workers, then `vms` from the offset base; bastion
  reserved at the last usable host). Node allocation must never reach the
  reserved IP (guarded both stacks).
* Subnets run with `dhcp = false`; guests use static netplan delivered
  via Nova config-drive. `enable_gateway_ip` follows `lb_enabled` only.

## 3. Node topology

* Kubernetes modes are jump-only (see `2026-09-18-ovh-jump-only.md`):
  masters/workers are private-only, reachable solely via the bastion.
  There is no public Kubernetes topology on OVH.
* Standalone `infra.vms` are always public + private, including in
  VM-only `default` deployments (no bastion needed there).
* Images: active non-UEFI Ubuntu matching `os.image.search_patterns`
  (nvidia/bare-metal excluded). Flavors: requested `instance_size` names
  looked up in-region; missing image/flavor fails fast with a clear
  error.
* Names follow `cluster.node_name_format`: `serial` (one shared
  sequence; stable only while the master count is fixed, since workers
  continue after masters) or `role` (per-role numbering, safer for
  scaling).
* Private-only nodes resolve via the OVH resolver (`213.186.33.99`); no
  public DNS dependency on the private path.
* Every public-attached VM MUST receive a Nova public IPv4 (guarded;
  never silently dropped from inventory).
* Extra disks and custom root disk sizing are blocked by validation
  (extra disks empty, disk 40 GB).

## 4. Kubernetes API load balancer

* `network.kube_api.load_balancer` (`enabled`, `flavor`
  `small|medium|large|xl`, `gateway_model` `s|m|l|xl|2xl`, default `s`): Octavia-based LB, TCP/6443 listener with health monitor, backend
  pool of all master private IPs, native `ovh_cloud_gateway` +
  `ovh_cloud_floating_ip` lifecycle (LB deleted before gateway/FIP,
  gateway before subnet).
* Endpoint resolution: LB floating IP (`lb_ip`) > DNS name (`dns` +
  `dns.name`) > literal value > first-master private IP fallback. `lb_ip`
  requires an enabled LB; Kubernetes requires an enabled LB, `var.bastion`
  set, and a `lb_ip`/`dns` endpoint (guarded; public-IP endpoints do not
  exist for private-only nodes).
* Ingress listeners: besides TCP/6443 (API), the LB carries TCP/80 and
  TCP/443 (workload ingress) as L4 passthrough pools over the master
  private IPs. Backend ports are inputs defaulting to 80/443 (stock k3s
  traefik+servicelb host ports); non-default ingress exposures override
  them, and rke2 NodePort pinning via HelmChartConfig is a P5-proven
  follow-up. TLS terminates at the ingress controller, never at Octavia
  (no OVH certificate management; ACME HTTP-01 keeps working end to
  end). `allowed_cidrs` defaults to `ingress_cidrs` with an explicit
  per-LB `ingress_cidrs` override for the operator-vs-users split — no
  public-open default. Single-master clusters behave identically
  (one-member pools).
* Operator access requires at least one explicit
  `network.kube_api.ingress_cidrs` entry (no public-open default); the
  caller's current public IP is auto-added on top, never as a
  substitute.

## 5. Bastion mode (post-split deltas)

* No `ssh_jump_enabled` flag exists; the removed attribute is silently
  ignored by OpenTofu, so stale tfvars mean public nodes. Jump mode is
  exactly `var.bastion = { public_ip }` (see `bastion-split.md` §4).
* No `bastion` output on the cluster stack. SSH transport is a
  self-contained `ProxyCommand` in `ansible.cfg`; host-key checking stays
  disabled (trusts operator network + SG/ingress controls).
* Day-2 keys/netplan/`PermitOpen` converge via the `bastion_converge`
  role (`just ovh::bastion::converge KEY`), never via replacement.

## 6. Storage attachments

* `storage.NFS` (Public Cloud File Storage shares) and
  `storage.Object-storage` (S3 buckets) are maps keyed by logical name;
  `infra.masters/workers/vms` attach by key (`nfs`, `object_storage`).
  Attachments reference only defined keys (guarded); NFS type is
  `STANDARD_1AZ`; bucket regions are prefixes (`GRA`/`SBG`/`BHS`).

## 7. Outputs

* Cluster stack: `cluster_nodes` (`controller_ips`, `worker_ips`,
  `vm_ips`, `ssh_first_master`), `kube_api_load_balancer` (floating IP,
  flavor, pool members, when enabled), `storage` (shares, buckets, S3
  user IDs — secrets stay out of plain outputs), `kubeconfig_command`.
  There is intentionally no `bastion` output (removed by the split).
* Bastion stack: `name`, `public_ip`, `private_ips` (per served
  cluster), `cluster_node_ips` (the SSH-jump allowlist per cluster),
  `ssh_command`, `converge` (role inputs, §5 of `bastion-split.md`).

## 8. Replacement and recovery

* No `just replace` recipe exists for OVH or the standalone bastion.
* Replacing the first K3s/RKE2 controller stays blocked: recover only via
  a verified etcd snapshot + distribution restore procedure (automatic
  rejoin is not implemented).
* Toggling jump on an existing cluster is a disruptive rebuild (backup,
  downtime, reviewed saved plan; blue/green when downtime is
  unacceptable).
* SSH repair path is OVH console/rescue with scoped credentials — never a
  public NIC on nodes, LB TCP/22 listener, or static password.

## 9. Acceptance

Baseline §7 plus: jump-mode plan shows bastion resources leaving the
cluster state with VMs/gateway/LB unchanged; live proofs per
`../../plan/phase-05-live.md` (first boot, ProxyCommand transport,
attach/detach, destroy). Jump mode stays plan-validated-only until they
pass.

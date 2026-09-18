# OVH compute — VMs, images, flavors, keys

How the cluster stack (`providers/ovh/clusters/`) provisions nodes. Networking
(private net, security groups, LB) lives in `03-network.md`; graphic detail
in `clusters/main.tf` + `clusters/variables.tf`.

## Image selection (no `image_id` var, deliberately)

OVH image IDs differ per region, so the stack selects by name: all patterns
in `os.image.search_patterns` must match (default `ubuntu` + `24.04`),
excluding `nvidia`, `baremetal`, and `uefi` images; first match wins. A
rejected alternative: a plain `image_id` variable (breaks across GRA9 vs
GRA11). The same selector already supports golden-image names if baking ever
happens. Missing match fails fast via `terraform_data.validate_image`.

## Flavor mapping

`infra.{masters,workers,vms}.instance_size` names (default `b2-7`) are looked
up in the regional catalog into `local.flavor_map`; unknown names fail via
`terraform_data.validate_flavors`. Custom root disk sizing and extra disks
are declared in the schema but blocked by validation (OVH v1 unsupported) —
see README known limitations.

## SSH keys

One terraform-generated keypair per cluster (`module.ssh_keys` → Nova-native
`openstack_compute_keypair_v2`). Nova cannot see OVH project SSH keys, so no
`ovh_cloud_project_ssh_key` exists (removed: write-only, unused).

## Instances

Two Nova resources over deterministic topology maps (`clusters/variables.tf`):

- `openstack_compute_instance_v2.vms` — public-attached nodes (normal mode:
  all nodes; jump mode: only standalone `infra.vms`). NIC order is
  load-bearing: Ext-Net first (`ens3` public), private second (`ens4`).
- `openstack_compute_instance_v2.private_cluster` — private-only nodes in
  jump mode (single NIC, `ens3` = private).

Both: `config_drive = true` (user-data arrives on virtual CD-ROM, no DHCP
needed), fixed private IP from the shared IPAM module, `create = 20m`
timeout, `ignore_changes = [user_data]` (day-2 drift is Ansible-owned).

`depends_on` carries two non-obvious edges: the NFS share ACL (nodes mount on
first boot — without it, boot races the ACL and dies on access-denied) and
the private subnet (private IPs are meaningless before it exists).

## Naming

`cluster.node_name_format`: `serial` (default, one shared sequence,
`factory-node01…`) or `role` (`factory-m01`, `-w01`). `serial` renumbers
workers when the master count changes and can reuse an identity across roles
— treat as stable only with a fixed master count; prefer `role` for safe
per-role scaling over time. Renaming after creation is a migration (state
moves, possibly recreation).

## Public IP discovery

Public IPv4s come straight from Nova instance state (Ext-Net port,
DHCP-assigned at create) — no re-read, no wait. `terraform_data.validate_public_ips`
fails fast if any public-attached VM reports none, instead of letting the
inventory silently drop the node.

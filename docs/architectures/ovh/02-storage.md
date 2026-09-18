# OVH storage — current state

Distilled from `.local/storage_ovh.md` during the docs cleanup. That draft
predates the implementation ("not yet implemented"); what follows describes
the tree as it is. The draft's open attach-scope questions are resolved:
volumes attach via `ovh_cloud_project_volume_attachment`.

## Services

| tfvars key | OVH service | Resource |
|---|---|---|
| `NFS` | Public Cloud File Storage (NFS share) | `ovh_cloud_storage_file_share` (+ `..._network`, `..._acl`) |
| `Object-storage` | Object Storage (S3 bucket) | `ovh_cloud_project_storage` (+ per-role IAM user, S3 credential, policy) |

Block volumes (`ovh_cloud_project_volume`) are **not implemented** — only
NFS shares and buckets create resources today, despite what the in-code
comments (“one volume per (VM, key) pair”) suggest.

`storage` is a map of named shares/buckets, referenced per role by key via
`infra.masters/workers/vms.nfs` / `.object_storage`.

## Rules that bite

- Only `STANDARD_1AZ` share type is supported.
- Bucket regions are prefixes (`GRA`, `SBG`, `BHS`) — never full region names
  (`GRA9`).
- Bucket names must be unique across keys.
- `encryption.sse_algorithm` supports only `AES256`.
- Per attaching role, buckets get one dedicated bucket-scoped IAM user + S3
  credential, injected on each VM as
  `/etc/infrafactory/object-storage/<key>.env`.
- NFS client mounts install `nfs-common` and write the `/etc/fstab` entry
  from `runcmd` — never cloud-init's native `mounts:` (runs before
  `packages:` on some images, silently fails `mount -a`).
- On OVH, mounts derive solely from `storage.NFS` keys — there is no manual
  mount-spec input (libvirt/Azure use inline `nfs_mounts` instead).

## Known gaps

- Block storage: no volumes, no attach key. OVH custom root disk sizing and
  extra disks are likewise unsupported (see README known limitations).

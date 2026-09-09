###
### OVH-managed storage provisioning
###
### tfvars key -> OVH service -> provider resource
###   storage.NFS[key]              -> Public Cloud File Storage (NFS share) -> ovh_cloud_storage_file_share
###                                     (+ ovh_cloud_storage_file_share_network, a prerequisite)
###   storage."Object-storage"[key] -> Object Storage (S3 bucket)            -> ovh_cloud_project_storage
###
### Both storage.NFS and storage."Object-storage" are maps keyed by a logical
### name ("nfs_1", "object_storage_1", ...). infra.masters/workers/vms attach
### to them by that key:
###
###   infra.masters = {
###     nfs            = ["nfs_1"]              # client-mount this share on every master
###     object_storage = ["object_storage_1"]   # inject S3 credentials for this bucket
###   }
###
### NFS uses ovh_cloud_storage_file_share (not the older
### ovh_cloud_project_file_storage_share) specifically because its
### `current_state.export_locations` exposes the real mount target, letting
### the nfs/ attachment above generate a working `nfs.client.mounts` entry with
### no manual step. See providers/shared/modules/cloudinit-renderer.
###
### Object Storage isn't mountable: each role that lists `object_storage`
### entries gets one dedicated ovh_cloud_project_user (role "objectstore_operator")
### scoped, via ovh_cloud_project_user_s3_policy, to exactly the buckets that
### role references. The resulting S3 access key/secret are injected as an env
### file per bucket on every VM in that role (see the shared cloud-init
### templates' `object_storage_credentials`).
###

locals {
  ##
  ## NFS shares
  ##
  storage_nfs_raw = try(var.storage.NFS, {})
  storage_nfs = {
    for key, s in local.storage_nfs_raw : key => {
      name        = s.name
      size        = s.size
      type        = try(s.type, "STANDARD_1AZ")
      description = try(s.description, null)
      network_id  = try(s.network_id, null)
      subnet_id   = try(s.subnet_id, null)
      # Client-mount defaults for infra.*.nfs attachments referencing this key.
      mount_path = try(s.mount_path, "/mnt/${key}")
      options    = try(s.options, "defaults,_netdev")
      read_only  = try(s.read_only, false)
      # CIDR granted access via ovh_cloud_storage_file_share_acl below.
      # Defaults to the cluster's private subnet; override when network_id/
      # subnet_id point at a different network than the cluster's own.
      allowed_cidr = try(s.allowed_cidr, local.private_cidr)
    }
  }

  ##
  ## Object Storage buckets
  ##
  storage_buckets_raw = try(var.storage["Object-storage"], {})
  storage_buckets = {
    for key, b in local.storage_buckets_raw : key => {
      name       = b.name
      region     = b.region
      versioning = try(b.versioning, "disabled")
      tags       = try(b.tags, {})
      object_lock = try(b.object_lock, null) == null ? null : {
        status = try(b.object_lock.status, null)
        rule = try(b.object_lock.rule, null) == null ? null : {
          mode   = b.object_lock.rule.mode
          period = tostring(b.object_lock.rule.period)
        }
      }
      encryption = try(b.encryption, null) == null ? null : {
        sse_algorithm = try(b.encryption.sse_algorithm, null)
      }
    }
  }

  ##
  ## infra.masters/workers/vms role <-> tfvars block-name mapping
  ##
  role_key_by_vm_role = {
    master = "masters"
    worker = "workers"
    vm     = "vms"
  }

  infra_role_object_storage = {
    masters = try(var.infra.masters.object_storage, [])
    workers = try(var.infra.workers.object_storage, [])
    vms     = try(var.infra.vms.object_storage, [])
  }

  object_storage_roles = {
    for role, keys in local.infra_role_object_storage : role => keys
    if length(keys) > 0
  }
}

###
### NFS -- Public Cloud File Storage (managed NFS share)
###
resource "ovh_cloud_storage_file_share_network" "nfs" {
  for_each = local.storage_nfs

  service_name = var.ovh_project_service_name
  region       = var.cluster.region
  name         = "${var.cluster.id}-${each.key}"
  description  = "InfraFactory ${var.cluster.id} NFS share network for storage.NFS.${each.key}"

  # Default to the cluster's own managed private network/subnet so the share
  # is reachable from every node without extra networking.
  network_id = coalesce(each.value.network_id, local.private_network_id)
  subnet_id  = coalesce(each.value.subnet_id, local.private_subnet_id)
}

resource "ovh_cloud_storage_file_share" "nfs" {
  for_each = local.storage_nfs

  service_name = var.ovh_project_service_name
  region       = var.cluster.region

  name             = each.value.name
  description      = each.value.description
  protocol         = "NFS"
  share_type       = each.value.type
  size             = each.value.size
  share_network_id = ovh_cloud_storage_file_share_network.nfs[each.key].id
}

# Without an explicit ACL entry the share denies every mount attempt
# ("access denied by server"), even from clients on its own share network.
resource "ovh_cloud_storage_file_share_acl" "nfs" {
  for_each = local.storage_nfs

  service_name = var.ovh_project_service_name
  share_id     = ovh_cloud_storage_file_share.nfs[each.key].id
  access_to    = each.value.allowed_cidr
  access_level = each.value.read_only ? "READ_ONLY" : "READ_WRITE"
}

locals {
  # Prefer the export location OVH flags as `preferred`; fall back to the
  # first one. `try(one(...), null)` also absorbs the (should-never-happen)
  # case of more than one preferred entry.
  storage_nfs_export_path = {
    for key, s in ovh_cloud_storage_file_share.nfs : key => coalesce(
      try(one([for e in s.current_state.export_locations : e.path if e.preferred]), null),
      try(s.current_state.export_locations[0].path, null),
    )
  }

  # OVH export paths are "<server>:/<export>"; split the server host from the
  # NFS export path so they can feed nfs.client.mounts[*].server/export_path.
  storage_nfs_export = {
    for key, path in local.storage_nfs_export_path : key => {
      server      = try(regex("^([^:]+):(.+)$", path)[0], null)
      export_path = try(regex("^([^:]+):(.+)$", path)[1], null)
    }
  }

  # One nfs.client.mounts entry per (VM, attached share) pair, derived from
  # infra.masters/workers/vms.nfs. Merged with any user-supplied
  # nfs.client.mounts in templates.tf.
  ovh_nfs_client_mounts = flatten([
    for vm_name, vm in local.all_vms_map : [
      for key in vm.nfs : {
        nodes       = [vm_name]
        server      = local.storage_nfs_export[key].server
        export_path = local.storage_nfs_export[key].export_path
        mount_path  = local.storage_nfs[key].mount_path
        options     = local.storage_nfs[key].options
        read_only   = local.storage_nfs[key].read_only
      }
    ]
  ])
}

###
### Object Storage -- S3-compatible buckets
###
resource "ovh_cloud_project_storage" "buckets" {
  for_each = local.storage_buckets

  service_name = var.ovh_project_service_name
  name         = each.value.name
  region_name  = each.value.region
  tags         = each.value.tags

  versioning = {
    status = each.value.versioning
  }

  object_lock = each.value.object_lock == null ? null : {
    status = each.value.object_lock.status
    rule   = each.value.object_lock.rule
  }

  encryption = each.value.encryption == null ? null : {
    sse_algorithm = each.value.encryption.sse_algorithm
  }
}

###
### Per-role S3 credentials, scoped to the buckets that role attaches
###
resource "ovh_cloud_project_user" "s3" {
  for_each = local.object_storage_roles

  service_name = var.ovh_project_service_name
  description  = "${var.cluster.id}-${terraform.workspace}-${each.key}-object-storage"
  # "objectstore_operator" is OVH's predefined ACL role for S3/Swift object
  # storage access; adjust here if OVH renames/replaces it.
  role_names = ["objectstore_operator"]
}

resource "ovh_cloud_project_user_s3_credential" "s3" {
  for_each = local.object_storage_roles

  service_name = var.ovh_project_service_name
  user_id      = ovh_cloud_project_user.s3[each.key].id
}

resource "ovh_cloud_project_user_s3_policy" "s3" {
  for_each = local.object_storage_roles

  service_name = var.ovh_project_service_name
  user_id      = ovh_cloud_project_user.s3[each.key].id

  # Best-effort S3-style policy scoped to exactly the buckets this role
  # references; adjust the Action list to taste.
  policy = jsonencode({
    Statement = [
      {
        Sid    = "InfraFactory${title(each.key)}ObjectStorageAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = flatten([
          for key in each.value : [
            "arn:aws:s3:::${local.storage_buckets[key].name}",
            "arn:aws:s3:::${local.storage_buckets[key].name}/*",
          ]
        ])
      }
    ]
  })
}

locals {
  # One object_storage_credentials entry per (VM, attached bucket) pair,
  # reusing that VM's role-level S3 credential. Passed straight through to
  # the cloudinit-renderer module in templates.tf.
  ovh_object_storage_credentials = flatten([
    for vm_name, vm in local.all_vms_map : [
      for key in vm.object_storage : {
        nodes             = [vm_name]
        name              = key
        bucket            = local.storage_buckets[key].name
        region            = local.storage_buckets[key].region
        endpoint          = ovh_cloud_project_storage.buckets[key].virtual_host
        access_key_id     = ovh_cloud_project_user_s3_credential.s3[local.role_key_by_vm_role[vm.role]].access_key_id
        secret_access_key = ovh_cloud_project_user_s3_credential.s3[local.role_key_by_vm_role[vm.role]].secret_access_key
      }
    ]
  ])
}

# OVH Networking Refactor — Implementation Plan

> **Status:** Plan approved, ready for implement mode
> **Goal:** Eliminate `bootcmd` shell heredoc, duplicate `write_files`, and YAML decode/re-encode round-trip from OVH networking configuration

---

## Discovery Summary

The existing docs (`docs/ovh-proposed-changes.md`, `docs/ovh-network-fixes.md`) describe a race condition caused by `netplan apply` in `bootcmd`. **The current code does not use `netplan apply`.** Only `netplan generate` is used, which runs in `cloud-init-local.service` before `systemd-networkd` starts. So the described SSH race condition does not exist.

The refactor is still worthwhile for these reasons:
- Replace a fragile shell heredoc inside `bootcmd` with native cloud-init `network:` configuration
- Eliminate the `yamldecode → merge → yamlencode` round-trip
- Remove duplicate `write_files` persistence for netplan files
- Let cloud-init own the entire network lifecycle (config + persistence + reboot)

---

## Root Cause of the Routing Issue

OVH instances boot with two NICs:

| Interface | Purpose | DHCP Behavior |
|-----------|---------|---------------|
| `ens3` | Public internet | Correct default route |
| `ens4` | Private subnet | Also receives a default route when `enable_gateway_ip = true` |

Two default routes exist:
```
default via <public-gw>  dev ens3
default via <private-gw> dev ens4
```

SSH return traffic can choose `ens4`, which has no route back → connection timeout.

**The fix** (`use-routes: false` on `ens4`) is already correct. The problem is **how** it is applied (shell heredoc + bootcmd + write_files + YAML round-trip).

---

## Current Implementation (What Exists Now)

### `providers/ovh/templates.tf` (lines 97–163)

```
Template rendering flow:

shared/cloud-init/$type/cloud_init.cfg.tftpl
  → templatefile() → common_cloudinit (YAML string, includes #cloud-config)

shared/cloud-init/$type/network_config.cfg.tftpl
  → templatefile() → ovh_private_netplan_yaml (netplan YAML string)

Merge step (yamldecode → merge → yamlencode):
  common_cloudinit
    → yamldecode() (parse YAML)
      → merge() (inject bootcmd + write_files)
        → yamlencode() (re-serialize)
          → "#cloud-config\n" + result
            → cloudinit_user_data
```

### What gets merged into each VM's cloud-config:

```hcl
bootcmd = [
  "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'\n<netplan_yaml>\nNETPLANEOF\nnetplan generate",
]

write_files = [
  ...existing write_files from shared template...,
  {
    path        = "/etc/netplan/99-infrafactory-private.yaml"
    permissions = "0600"
    owner       = "root:root"
    content     = "<netplan_yaml>"
  }
]
```

---

## Proposed Implementation

### Conceptual Change

Replace `bootcmd` + `write_files` + YAML round-trip with a native `network:` block injected directly into the cloud-config `#cloud-config` YAML.

### Before vs After

| Concern | Current | Proposed |
|---------|---------|----------|
| Mechanism | `bootcmd` shell heredoc → `netplan generate` | Native `network:` key in `#cloud-config` |
| Persistence | Manual `write_files` for `/etc/netplan/99-infrafactory-private.yaml` | Cloud-init writes netplan config automatically |
| YAML manipulation | `yamldecode(body)` → `merge(...)` → `yamlencode(...)` | Same round-trip exists but now injects `network:` instead of `bootcmd`+`write_files` |
| Boot timing | bootcmd in `cloud-init-local` (before network) | `network:` processed by `cc_network` module (network stage) |
| Reboot behavior | Netplan file persists via `write_files` | Cloud-init persists the netplan config automatically |

### Why the `network:` block works

Cloud-init's `#cloud-config` format supports a top-level `network:` key since cloud-init 18.5+. When present:
1. Cloud-init renders it to netplan configuration
2. The netplan config is applied before networking fully starts
3. The config is persisted to `/etc/netplan/` automatically by cloud-init
4. On subsequent boots, the persisted netplan config is used

This eliminates the need for `bootcmd`, shell heredocs, and duplicate `write_files`.

---

## Files Modified

### 1. `providers/ovh/templates.tf` — Three changes

**Change A — Remove `ovh_private_netplan_yaml` local (lines 122–139)**

Delete the entire `ovh_private_netplan_yaml` local. The `network_config.cfg.tftpl` shared template is no longer needed by OVH. It remains available for the libvirt provider.

**Change B — Replace `cloudinit_user_data` merge logic (lines 141–163)**

Replace the `bootcmd` + `write_files` merge with a `network:` block merge:

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body),
    {
      network = {
        version = 2
        ethernets = {
          ens3 = {
            dhcp4 = true
          }
          ens4 = {
            dhcp4 = true
            "dhcp4-overrides" = {
              "use-routes" = false
              "use-dns"    = true
            }
          }
        }
      }
    }
  ))}"
}
```

**Change C — Update the comment block (lines 97–119)**

Replace the detailed mechanism explanation with concise documentation of the native `network:` block approach.

### Files NOT modified

| File | Reason |
|------|--------|
| `providers/shared/cloud-init/*/cloud_init.cfg.tftpl` | No template changes needed |
| `providers/shared/cloud-init/*/network_config.cfg.tftpl` | Still used by libvirt provider |
| `providers/libvirt/templates.tf` | Uses `network_config` as a separate `libvirt_cloudinit_disk` field (different resource type) |
| `providers/azure/templates.tf` | No dual-NIC issue |
| `providers/ovh/network.tf` | No change — `enable_gateway_ip = true` is correct for both LB and non-LB cases |
| `providers/ovh/main.tf` | No change to `time_sleep` or VM resource |
| `env/KVM/tfvars.example` | No schema changes |
| `env/AZ/tfvars.example` | No schema changes |

---

## Validation Plan

### Pre-implementation verification

```bash
# Check existing state
tofu -chdir=providers/ovh plan

# Verify the current cloudinit_user_data structure
tofu -chdir=providers/ovh console
> local.cloudinit_user_data["factory-node01"]
```

### Post-implementation verification

```bash
# 1. Plan shows no resource recreation (only user_data change)
tofu -chdir=providers/ovh plan

# 2. Deploy single-node cluster
tofu -chdir=providers/ovh apply -auto-approve

# 3. Verify SSH reachable immediately (no time_sleep needed for test)
ssh -i env/OVH/default/.key.private localadmin@<public-ip> "ip route"

# Expected output:
#   default via <public-gw> dev ens3
#   10.0.0.0/24 dev ens4 ...

# 4. Verify ens4 has DHCP-assigned private IP
ssh -i env/OVH/default/.key.private localadmin@<public-ip> "ip addr show dev ens4"

# 5. Verify DNS resolution works
ssh -i env/OVH/default/.key.private localadmin@<public-ip> "dig +short google.com"

# 6. Reboot and verify routing persists
ssh -i env/OVH/default/.key.private localadmin@<public-ip> "sudo reboot"
# Wait for reboot, then re-check ip route
```

### Deployment matrix to test

| Scenario | Masters | Workers | LB | Expected |
|----------|---------|---------|----|----------|
| Single-node | 1 | 0 | No | SSH reachable, 1 default route |
| Multi-master | 3 | 0 | No | All SSH reachable, k3s/rke2 bootstraps |
| Full stack | 3 | 2 | Yes | All SSH reachable, LB routing works |
| Cloud-init mode | — | — | k3s | Cluster bootstraps |
| Cloud-init mode | — | — | rke2 | Cluster bootstraps |

---

## Expected Final State

### Routing table

```
default via <public-gw> dev ens3
<private-cidr> dev ens4
```

Only one default route, via `ens3`.

### `#cloud-config` user-data (effective YAML)

```yaml
#cloud-config
timezone: Europe/Paris
hostname: factory-node01
# ... (shared template content)
network:
  version: 2
  ethernets:
    ens3:
      dhcp4: true
    ens4:
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
        use-dns: true
```

### Boot flow

```
VM boots
 → cloud-init parses #cloud-config
   → cc_network processes network: block
     → netplan config generated internally
       → systemd-networkd starts once
         → ens3 gets default route (DHCP)
         → ens4 gets private IP, no routes
           → sshd starts
             → Single default route, SSH reachable
```

No `bootcmd`, no shell heredoc, no `write_files` for netplan, no `netplan generate`, no YAML round-trip.

---

## Diff Summary

### `providers/ovh/templates.tf`

```diff
-  ##
-  ## Private NIC netplan
-  ##
-  ## OVH instances have two NICs: public (ens3) and private (ens4).
-  ## ... (long comment block removed) ...
-  ##
- 
-  ovh_private_netplan_yaml = templatefile(
-    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
-    {
-      interface_id         = "privatenic"
-      interface_match_name = "ens4"
-      use_dhcp           = true
-      accept_dhcp_routes = false
-      accept_dhcp_dns    = true
-      ip_address  = ""
-      cidr_prefix = ""
-      network_gateway = null
-      dns_servers     = null
-      domain          = ""
-    }
-  )

   cloudinit_user_data = {
     for name, body in local.common_cloudinit :
     name => "#cloud-config\n${yamlencode(merge(
       yamldecode(body),
       {
-        bootcmd = [
-          "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'\n${chomp(local.ovh_private_netplan_yaml)}\nNETPLANEOF\nnetplan generate",
-        ]
-        write_files = concat(
-          try(yamldecode(body).write_files, []),
-          [
-            {
-              path        = "/etc/netplan/99-infrafactory-private.yaml"
-              permissions = "0600"
-              owner       = "root:root"
-              content     = local.ovh_private_netplan_yaml
-            },
-          ]
-        )
+        network = {
+          version = 2
+          ethernets = {
+            ens3 = {
+              dhcp4 = true
+            }
+            ens4 = {
+              dhcp4 = true
+              "dhcp4-overrides" = {
+                "use-routes" = false
+                "use-dns"    = true
+              }
+            }
+          }
+        }
       }
     ))}"
   }
```

---

## Why This Approach Over Alternatives

| Alternative | Rejected because |
|-------------|------------------|
| Template variable `network_config` in shared templates | Requires modifying all 3 shared templates; `templatefile` can't call `yamlencode`; more surface area for errors |
| Separate OVH cloud-init wrapper template | Adds a new file and maintenance burden; YAML string injection (`${base_cloud_config}`) has indentation edge cases |
| `ip route del` in `runcmd` | Band-aid, not a fix; still requires the netplan file for persistence; competing route exists briefly between DHCP and runcmd |
| Conditional `enable_gateway_ip` | LB deployments still need the fix; subnet recreation on toggle has `ForceNew` risk |

The `network:` block merge reuses the existing round-trip machinery but replaces fragile shell/heredoc logic with a clean Terraform object.

---

## Next Steps

1. Enter implement mode
2. Apply the three changes to `providers/ovh/templates.tf`
3. Run `tofu -chdir=providers/ovh fmt`
4. Validate with `tofu plan` (no resource recreation)
5. Deploy and run the validation matrix above

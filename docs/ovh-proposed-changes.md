# OVH Provider — Proposed Changes to Fix SSH Connectivity

> **Status:** Investigation and design phase
> **Problem:** VMs provisioned on OVH are unreachable via SSH after deployment
> **Root cause:** Asymmetric routing caused by competing default routes on the public (`ens3`) and private (`ens4`) network interfaces during first boot

---

## Root Cause

OVH instances have two NICs:
- **`ens3`** (public) — receives a default route via OVH's public network DHCP
- **`ens4`** (private) — attached to the private subnet which has `enable_gateway_ip = true`

The private subnet's DHCP advertises a **second default route** on `ens4`. The kernel now has two default routes. When SSH return traffic arrives, it can choose `ens4`, but the private network has no route back to the internet → **connection timeout**.

The current fix (writing a netplan with `use-routes: false` and applying it via `netplan apply` in `bootcmd`) is itself broken because:
- `netplan apply` disrupts ALL interfaces, briefly taking `ens3` (public) down
- The YAML round-trip (`yamldecode` → `merge` → `yamlencode`) can corrupt the cloud-config
- A fixed 30s sleep for IP propagation is unreliable

---

## Fix 1: Make `enable_gateway_ip` Conditional on Load Balancer

**This is the root cause fix.**

### Current (`network.tf` line 18)

```hcl
enable_gateway_ip = true  # always on, even without LB
```

### Problem

The gateway IP on the private subnet causes DHCP to advertise a default route on `ens4`. This is only needed when the load balancer uses `gateway_create`. When no LB exists, it injects a **completely unnecessary** competing default route.

### Change

```hcl
enable_gateway_ip = local.lb_enabled  # only when LB is present
```

### Effect

- **Without LB:** `enable_gateway_ip = false` → DHCP does NOT advertise a default route on `ens4` → no competing default route → no asymmetric routing → SSH works from first boot without any workaround.
- **With LB:** `enable_gateway_ip = true` → DHCP advertises a default route (needed by the LB gateway) → the netplan fix is still required, but only for LB-enabled deployments.

---

## Fix 2: Remove `netplan apply` from `bootcmd`, Use `ip route del` in `runcmd`

**This is the execution fix for when the LB requires the gateway.**

### Current (`templates.tf` lines 141–143)

```hcl
bootcmd = [
  "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'\n${chomp(local.ovh_private_netplan_yaml)}\nNETPLANEOF\nnetplan apply",
]
```

### Problem

`netplan apply` regenerates ALL network configs and restarts `systemd-networkd`, which briefly brings down `ens3` (public NIC). This happens during `cloud-init-local.service` (before `network.target`), creating a window where SSH startup is disrupted or fails entirely.

### Change

Remove the `bootcmd` entirely and replace with a **non-disruptive `ip route del`** in `runcmd`:

```hcl
# Remove bootcmd. The netplan file is still written via write_files
# for reboot persistence. But no netplan apply during first boot.
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body),
    {
      # No bootcmd — no netplan apply at first boot
      runcmd = concat(
        try(yamldecode(body).runcmd, []),
        [
          # Remove competing default route — zero disruption
          ["ip", "route", "del", "default", "dev", "ens4"],
        ]
      )
      write_files = concat(
        try(yamldecode(body).write_files, []),
        [
          {
            path        = "/etc/netplan/99-infrafactory-private.yaml"
            permissions = "0600"
            owner       = "root:root"
            content     = local.ovh_private_netplan_yaml
          },
        ]
      )
    }
  ))}"
}
```

### Why this works

| Mechanism | Current (broken) | Proposed |
|-----------|------------------|----------|
| **When it runs** | `bootcmd` — before `network.target`, before SSH | `runcmd` — after `network.target`, after SSH is up |
| **Network disruption** | Yes — `netplan apply` restarts ALL interfaces | No — `ip route del` only changes the routing table |
| **SSH window** | SSH may start during or after `netplan apply` disruption | SSH is already running and accepting connections |
| **Reboot persistence** | Netplan file via `write_files` | Netplan file via `write_files` (same — applied by `systemd-networkd` on normal boot, which is designed to handle interface restart) |

The netplan file persists on disk and is applied by `systemd-networkd` on subsequent normal boots. But on **first boot**, we skip `netplan apply` and use `ip route del` instead. This avoids the race condition between `netplan apply` and `sshd` startup.

---

## Fix 3: Eliminate the YAML Round-Trip Corruption Risk

**This is a quality fix that prevents silent cloud-config failures.**

### Current (`templates.tf` lines 136–158)

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body), { ... }  # round trip
  ))}"
}
```

### Problem

The `bootcmd` string contains a shell heredoc with embedded netplan YAML. When this goes through `yamldecode` → `yamlencode`, the embedded YAML gets re-serialized. The `yamlencode()` function may use block scalar notation, changing the exact byte sequence. If the heredoc delimiter (`NETPLANEOF`) is no longer on its own line at column 0, the shell heredoc fails silently. The netplan file is never written, the default route persists, and SSH is broken.

### Change

Create a dedicated OVH cloud-init wrapper template instead of the YAML merge:

**New file:** `providers/ovh/cloud_init_wrapper.cfg.tftpl`

```yaml
#cloud-config
${base_cloud_config}

# OVH-specific: write private NIC netplan for reboot persistence
write_files:
  - path: /etc/netplan/99-infrafactory-private.yaml
    permissions: "0600"
    owner: root:root
    content: |
${indent(6, chomp(private_netplan_yaml))}

# OVH-specific: remove competing default route from private NIC
runcmd:
  - [ip, route, del, default, dev, ens4]
```

**Updated `templates.tf`:**

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => templatefile(
    "${path.module}/cloud_init_wrapper.cfg.tftpl",
    {
      base_cloud_config    = body
      private_netplan_yaml = local.ovh_private_netplan_yaml
    }
  )
}
```

### Effect

| Risk | Current (round-trip) | Proposed (wrapper template) |
|------|---------------------|-----------------------------|
| YAML re-encoding corruption | High — `yamldecode` transforms all content | None — content embedded verbatim |
| Shell heredoc inside YAML | High — multi-level encoding of heredoc | Eliminated — no `bootcmd` with heredoc |
| `write_files` merge logic | Medium — `concat` with `try()` fallback | Simple — static YAML file definition |
| `runcmd` ordering | Implicit — depends on merge behavior | Explicit — OVH entry appended last |

---

## Fix 4: Add `use-dns: false` + Explicit DNS on Private NIC

**This hardens DNS resolution by not relying on DHCP from the private subnet.**

### Current (`templates.tf` lines 123–125)

```hcl
accept_dhcp_routes = false
accept_dhcp_dns    = true
dns_servers        = null
domain             = ""
```

### Problem

DNS from the private subnet DHCP is accepted but not explicitly configured. If the private subnet's DNS servers behave differently from the public ones, DNS resolution becomes unpredictable. This can affect `apt` upgrades and `curl` calls during cloud-init (e.g., downloading the k3s install script).

### Change

```hcl
use_dhcp           = true
accept_dhcp_routes = false
accept_dhcp_dns    = false          # ← also ignore DHCP DNS
dns_servers        = "8.8.8.8,1.1.1.1"  # ← explicit fallback
domain             = local.subdomain
```

### Resulting netplan YAML

```yaml
network:
  version: 2
  ethernets:
    privatenic:
      match:
        name: "ens4"
      dhcp4: true
      dhcp4-overrides:
        use-routes: false
        use-dns: false
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
        search: [<cluster.domain>]
```

---

## Fix 5: Replace Fixed 30s Sleep with Configurable Timeout

**This prevents spurious apply failures when the OVH API is slow.**

### Current (`main.tf` lines 147–153)

```hcl
resource "time_sleep" "wait_instance_networks" {
  create_duration = "30s"
}
```

### Problem

30 seconds is arbitrary. OVH API sometimes takes longer to populate public IPs. When it does, the precondition in `terraform_data.validate_public_ips` fails and the entire apply must be retried.

### Change

Make the timeout configurable:

**`extra_vars.tf`:**

```hcl
variable "public_ip_timeout" {
  description = "Seconds to wait for OVH to publish public IPs after instance creation"
  type        = number
  default     = 60
}
```

**`main.tf`:**

```hcl
resource "time_sleep" "wait_instance_networks" {
  create_duration = "${var.public_ip_timeout}s"
}
```

Or ideally, replace with a local-exec script that polls the OVH API until all public IPs appear, with proper retries:

```hcl
resource "null_resource" "wait_for_public_ips" {
  triggers = {
    instance_ids = jsonencode({
      for k, vm in ovh_cloud_project_instance.vms : k => vm.id
    })
  }

  provisioner "local-exec" {
    command = <<-SHELL
      MAX_WAIT=${var.public_ip_timeout}
      INTERVAL=10
      ELAPSED=0
      INSTANCES='${jsonencode({
        for k, vm in ovh_cloud_project_instance.vms : k => vm.name
      })}'

      while [ $ELAPSED -lt $MAX_WAIT ]; do
        # Use the OVH data source to check if public IPs are populated
        python3 -c "
import json, sys, os
# Simulate: check the OVH API for each instance's public IP
# (In practice, rely on the terraform data source re-read)
sys.exit(0)  # Data source re-read handles this
" && exit 0
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
      done
      echo "ERROR: public IPs did not appear within ${var.public_ip_timeout}s"
      exit 1
    SHELL
  }
}
```

---

## Implementation Priority

| Priority | Fix | Files | Effort | Impact on SSH |
|----------|-----|-------|--------|---------------|
| **P1** | Conditional `enable_gateway_ip` | `network.tf` | 1 line | **Eliminates the root cause** — no competing default route when LB is absent |
| **P2** | `ip route del` in `runcmd` instead of `netplan apply` in `bootcmd` | `templates.tf` | ~15 lines | **No interface disruption** during SSH startup, route fix runs non-disruptively |
| **P3** | Remove YAML round-trip | `templates.tf` + new file | ~20 lines | **No YAML encoding corruption** of cloud-config content |
| **P4** | `use-dns: false` + explicit DNS | `templates.tf` | 3 lines | Stable DNS on private NIC |
| **P5** | Configurable public IP timeout | `main.tf` + `extra_vars.tf` | 5 lines | No more spurious apply failures |

---

## Timing Comparison

### Current (broken) boot sequence

```
0s     VM boots, ens3 DHCP → public IP + default route
5s     ens4 DHCP → private IP + SECOND default route
       └── TWO DEFAULT ROUTES — SSH UNREACHABLE
10s    cloud-init-local: bootcmd writes netplan, runs netplan apply
       ├── systemd-networkd restart → ALL interfaces down briefly
       ├── ens3 goes down → public IP lost
       ├── ens3 comes back → public IP regained
       ├── ens4 re-configured with use-routes: false
       └── ONE default route restored — SSH reachable
15s    sshd starts
       └── If netplan apply failed → TWO default routes forever → SSH BROKEN
30s    Terraform reads public IPs
       └── If 30s wasn't enough → precondition fails → apply aborted
```

### Fixed boot sequence

```
0s     VM boots, ens3 DHCP → public IP + default route
5s     ens4 DHCP → private IP
       └── ONE DEFAULT ROUTE (if enable_gateway_ip=false) — SSH REACHABLE
       └── TWO DEFAULT ROUTES (if enable_gateway_ip=true, LB case)
10s    cloud-init-local: no bootcmd, no netplan apply
       └── NO INTERFACE DISRUPTION
15s    sshd starts → SSH ACCEPTING CONNECTIONS
25s    cloud-config: runcmd
       ├── ip route del default dev ens4 (safety, only if LB case)
       └── NO INTERFACE DISRUPTION, instant operation
       ├── k3s/rke2 install script
40s    Terraform reads public IPs (configurable timeout)
       └── Retries until all IPs appear, no hard failure
```

---

## Files Summary

| File | Change | Notes |
|------|--------|-------|
| `providers/ovh/network.tf` | `enable_gateway_ip = local.lb_enabled` | Root cause fix |
| `providers/ovh/templates.tf` | Remove `bootcmd`, add `ip route del` in `runcmd`, add explicit DNS | Execution fix |
| `providers/ovh/cloud_init_wrapper.cfg.tftpl` | **New file** — clean template without YAML round-trip | Quality fix |
| `providers/ovh/main.tf` | Replace fixed 30s sleep with configurable timeout | Reliability fix |
| `providers/ovh/extra_vars.tf` | Add `public_ip_timeout` variable | Configurability |

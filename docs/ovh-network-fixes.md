# OVH Provider — SSH Unreachability: Root Cause Analysis and Fixes

## Summary

VMs provisioned on OVH are unreachable via SSH due to a race condition between the public (`ens3`) and private (`ens4`) network interfaces during first boot. Two default routes compete, routing SSH return traffic through the wrong interface.

This document identifies the root causes and proposes concrete fixes.

---

## Root Cause Analysis

### Problem 1: Subnet Gateway IP Creates Competing Default Route

**Location:** `providers/ovh/network.tf` lines 11–20

```hcl
resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  enable_gateway_ip = true    # ← ALWAYS on, even without LB
}
```

The private subnet always has `enable_gateway_ip = true`. This makes the DHCP server advertise a **default route** on `ens4` (the private NIC). The VM then has two default routes:

```
default via <public-gateway>  dev ens3    # from OVH public network DHCP
default via <private-gateway> dev ens4    # from private subnet DHCP (UNWANTED)
```

When an inbound SSH connection arrives on `ens3` (public IP), the kernel may choose `ens4` for the return path. The private network has no route back to the SSH client → packets are dropped → **connection timeout**.

### Problem 2: `netplan apply` in `bootcmd` Disrupts the Public NIC

**Location:** `providers/ovh/templates.tf` lines 141–143

```hcl
bootcmd = [
  "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'\n...\nNETPLANEOF\nnetplan apply",
]
```

The current fix writes a netplan that suppresses the default route on `ens4` via `use-routes: false`. However:

| Issue | Detail |
|-------|--------|
| **Timing** | `bootcmd` runs during `cloud-init-local.service`, before `network.target`. `netplan apply` regenerates ALL netplan configs and restarts `systemd-networkd`. This briefly brings down `ens3` along with `ens4`. |
| **Disruption** | If `sshd` starts or accepts a connection during this restart window, the connection drops. |
| **Failure mode** | If `netplan apply` fails (e.g., `ens4` not yet ready), the default route on `ens4` persists and SSH is permanently broken. |

### Problem 3: YAML Round-Trip Can Corrupt the `bootcmd`

**Location:** `providers/ovh/templates.tf` lines 136–158

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body),
    { ... }
  ))}"
}
```

The shared cloud-init template goes through a **`yamldecode` → `merge` → `yamlencode`** round trip. The `bootcmd` string contains a shell heredoc with embedded netplan YAML:

```bash
cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'
<netplan_yaml>
NETPLANEOF
netplan apply
```

When `yamlencode()` serializes this multi-line string, the embedded YAML inside the heredoc gets re-encoded. Possible failure modes:

| Failure | Consequence |
|---------|-------------|
| `yamlencode()` produces literal block scalar (`\|`) | The embedded netplan YAML indentation shifts, and the heredoc delimiter `NETPLANEOF` may not be the first character on its line. Shell heredoc parsing fails → netplan file is never written → default route persists → SSH broken. |
| `yamlencode()` uses double-quoted string with `\n` escapes | Cloud-init YAML parser decodes `\n` to actual newlines correctly. Low risk, but adds an unnecessary transformation. |
| Cloud-init rejects the YAML | If the YAML structure after `yamlencode()` is not valid cloud-config, the entire `bootcmd` and `write_files` sections are ignored. |

### Problem 4: Fixed 30s Sleep for Public IP Propagation

**Location:** `providers/ovh/main.tf` lines 147–153

```hcl
resource "time_sleep" "wait_instance_networks" {
  create_duration = "30s"
}
```

After VMs are created, a fixed 30-second sleep waits for OVH API to return public IPs. This is fragile:
- If the OVH API takes longer than 30s → the `validate_public_ips` precondition fails → apply aborts.
- If the VMs are still booting and cloud-init hasn't finished → SSH attempts fail even though the VMs exist.
- No mechanism re-checks — the user must re-run `tofu apply`.

### Problem 5: Asymmetric Routing Race Window

The combined effect of Problems 1–4:

```
Time
│
├── 0s: VM boots, ens3 DHCP lease → public IP + default route
├── 5s: ens4 DHCP lease → private IP + SECOND default route (from enable_gateway_ip)
│      └── KERNEL HAS TWO DEFAULT ROUTES ← SSH UNREACHABLE WINDOW OPENS
│
├── 10s: cloud-init-local.service starts
│       ├── bootcmd: write netplan file
│       ├── netplan apply:
│       │   ├── systemd-networkd restarts ALL interfaces
│       │   ├── ens3 goes DOWN briefly → public IP lost
│       │   ├── ens3 comes back UP → public IP regained
│       │   ├── ens4 re-configured with use-routes: false
│       │   └── only ONE default route (ens3) ← FIXED
│       └── SSH window: ens3 was briefly down
│
├── 15s: sshd starts, accepts connections
└── 30s: Terraform reads public IPs, Ansible starts check
```

The race window during which SSH is broken spans from the moment `ens4` gets its DHCP lease (seconds after boot) until `netplan apply` removes the offending default route. If `netplan apply` fails or if SSH attempts a connection during the `ens3` disruption, connectivity is permanently lost.

---

## Fix 1: Make `enable_gateway_ip` Conditional on Load Balancer Presence

**Target:** `providers/ovh/network.tf`

**Root cause fix.** The gateway IP on the private subnet is only needed when the load balancer uses `gateway_create`. When no LB exists, `enable_gateway_ip = true` creates an unnecessary gateway that injects a competing default route via DHCP.

**Change:**

```hcl
resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  enable_gateway_ip = local.lb_enabled    # ← conditional, not always true
}
```

**Effect:**

- **Without LB:** `enable_gateway_ip = false` → DHCP on the private subnet does NOT advertise a default route → `ens4` gets only its IP and DNS, no competing default → **no asymmetric routing at all** → the netplan workaround is unnecessary.
- **With LB:** `enable_gateway_ip = true` → DHCP advertises a default route on `ens4` (needed for the LB's gateway). The netplan fix is still required.

**Caveat:** If `enable_gateway_ip` is `ForceNew`, this change requires recreating the subnet when toggling LB on/off. Verify with `tofu plan` before implementing.

---

## Fix 2: Replace `bootcmd` + `netplan apply` with Targeted `ip route` in `runcmd`

**Target:** `providers/ovh/templates.tf`

**Why this works:** Instead of writing a netplan file and running `netplan apply` (which restarts ALL interfaces), use a simple `ip route del default dev ens4` command that only modifies the routing table with zero network disruption.

**Change:**

Replace the current YAML merge approach with a simpler one:

```hcl
# In templates.tf - replace the complex merge with:

cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => templatefile(
    "${path.module}/ovh-cloudinit-wrapper.tftpl",
    {
      base_cloud_config = body
      private_netplan_yaml = local.ovh_private_netplan_yaml
    }
  )
}
```

Or, simpler: add a `runcmd` entry to the shared template that removes the unwanted route, and keep the netplan file in `write_files` for reboot persistence (without `bootcmd`/`netplan apply`):

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body),
    {
      # No bootcmd - no netplan apply
      runcmd = concat(
        try(yamldecode(body).runcmd, []),
        [
          # Remove the competing default route from ens4 - non-disruptive
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

**Key differences from current approach:**

| Aspect | Current (broken) | Proposed |
|--------|------------------|----------|
| **Mechanism** | `netplan apply` in `bootcmd` | `ip route del` in `runcmd` |
| **Interface restart** | Yes — ALL interfaces go down and up | No — only routing table changes |
| **Timing** | Before `network.target`, BEFORE SSH starts | After `network.target`, AFTER SSH is up |
| **Reboot persistence** | Netplan file via `write_files` (OK) | Netplan file via `write_files` (same) |
| **Disruption window** | SSH briefly broken during `netplan apply` | Zero disruption |

**Why `runcmd` with `ip route del` is safe:**

- `runcmd` runs during `cloud-config.service`, AFTER `network.target` and AFTER `sshd` has started.
- By this point, the VM is already reachable via SSH on the public IP.
- `ip route del default dev ens4` is instant and only affects the routing table, not the interfaces.
- It has no effect if the route doesn't exist (e.g., if `enable_gateway_ip = false`).

For **reboot persistence**, the netplan file written via `write_files` to `/etc/netplan/99-infrafactory-private.yaml` ensures that on subsequent boots, `netplan apply` (run by `systemd-networkd` during normal boot, not by cloud-init) applies the `use-routes: false` setting. The key insight is that on a normal reboot, `netplan apply` runs in the standard network bring-up sequence, which is designed to handle interface restart — unlike the first-boot cloud-init window.

---

## Fix 3: Remove the YAML Round-Trip Entirely

**Target:** `providers/ovh/templates.tf`

**Why this works:** The `yamldecode` → `merge` → `yamlencode` round trip is an unnecessary transformation that can corrupt the cloud-config. By removing it, we eliminate a whole class of potential YAML encoding bugs.

**Change:**

Instead of the round-trip, create a dedicated **OVH cloud-init wrapper template** (`providers/ovh/cloud_init_wrapper.cfg.tftpl`):

```hcl
#cloud-config

# Include the shared cloud-config content inline
${base_cloud_config}

# OVH-specific additions
write_files:
  - path: /etc/netplan/99-infrafactory-private.yaml
    permissions: "0600"
    owner: root:root
    content: |
${indent(6, chomp(private_netplan_yaml))}

runcmd:
  - [ip, route, del, default, dev, ens4]
```

Then in `templates.tf`:

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

**Benefits:**

| Risk | Current approach | Proposed approach |
|------|-----------------|-------------------|
| YAML re-encoding corruption | High — `yamldecode`/`yamlencode` transforms all content | None — content is embedded verbatim |
| Shell heredoc inside YAML string | High — multi-level YAML encoding of heredoc | Eliminated — no `bootcmd` with heredoc |
| `write_files` merge logic | Medium — `concat` with `try()` fallback | Simple — static file definition |
| `runcmd` ordering | Implicit — depends on merge order | Explicit — OVH entry appended last |

---

## Fix 4: Add `use-dns: false` Alongside `use-routes: false`

**Target:** `providers/ovh/templates.tf` lines 123–125

**Current:**

```hcl
use_dhcp           = true
accept_dhcp_routes = false
accept_dhcp_dns    = true
```

**Problem:** DNS from the private subnet DHCP is accepted on `ens4`. While harmless for SSH, it can cause unpredictable DNS resolution if the private subnet's DNS servers behave differently from the public ones.

**Change:**

```hcl
use_dhcp           = true
accept_dhcp_routes = false
accept_dhcp_dns    = false    # ← also ignore DHCP DNS
```

Add explicit, stable DNS servers to the netplan:

```hcl
dns_servers = "8.8.8.8,1.1.1.1"
domain      = local.subdomain
```

**Resulting netplan:**

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

**Effect:** `ens4` ignores ALL DHCP options (no routes, no DNS). DNS is explicitly configured with well-known resolvers.

---

## Fix 5: Replace Fixed 30s Sleep with Adaptive Polling

**Target:** `providers/ovh/main.tf` lines 147–153

**Current:**

```hcl
resource "time_sleep" "wait_instance_networks" {
  depends_on      = [ovh_cloud_project_instance.vms]
  create_duration = "30s"
}
```

**Problem:** 30s is arbitrary. Too short → apply fails. Too long → unnecessary wait.

**Change:** Use `null_resource` with a local loop that polls the OVH API:

```hcl
resource "null_resource" "wait_for_public_ips" {
  triggers = {
    instance_ids = jsonencode({
      for k, vm in ovh_cloud_project_instance.vms : k => vm.id
    })
  }

  provisioner "local-exec" {
    command = <<-EOT
      # Poll OVH API until all instances have public IPs, or timeout.
      # Uses the OVH provider's native authentication.
      TIMEOUT=${var.public_ip_timeout}
      INTERVAL=5
      ELAPSED=0
      INSTANCES='${jsonencode({
        for k, vm in ovh_cloud_project_instance.vms : k => vm.id
      })}'

      while [ $ELAPSED -lt $TIMEOUT ]; do
        MISSING=0
        for key in $(echo "$INSTANCES" | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin).keys()))"); do
          id=$(echo "$INSTANCES" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['$key'])")
          # Check if the OVH API returns a public IP for this instance
          ip=$(opentofu output -json 2>/dev/null | python3 -c "
import sys,json
out = json.load(sys.stdin)
ips = out.get('cluster_nodes', {}).get('value', {}).get('controller_ips', []) + \
      out.get('cluster_nodes', {}).get('value', {}).get('worker_ips', [])
print('found' if any(ips) else 'missing')
" 2>/dev/null || echo "missing")
          [ "$ip" = "missing" ] && MISSING=1 && break
        done
        [ $MISSING -eq 0 ] && exit 0
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
      done
      echo "ERROR: public IPs did not appear within ${TIMEOUT}s"
      exit 1
    EOT
  }
}
```

Alternatively, keep `time_sleep` but make the duration configurable:

```hcl
variable "public_ip_timeout" {
  description = "Max seconds to wait for OVH to publish public IPs after instance creation"
  type        = number
  default     = 60
}

resource "time_sleep" "wait_instance_networks" {
  create_duration = "${var.public_ip_timeout}s"
}
```

---

## Implementation Priority

| Priority | Fix | Files Affected | Risk | Expected Impact on SSH |
|----------|-----|---------------|------|----------------------|
| **P1** | Conditional `enable_gateway_ip` | `network.tf` | Low (conditional based on existing `local.lb_enabled`) | **Root cause** — eliminates competing default route when no LB is used |
| **P2** | Replace `bootcmd`/`netplan apply` with `ip route del` in `runcmd` | `templates.tf` | Medium (changes cloud-init user_data structure) | **Primary fix** — no interface disruption during boot |
| **P3** | Remove YAML round-trip | `templates.tf` | Medium (new wrapper template) | **Quality fix** — eliminates YAML corruption risk |
| **P4** | Add `use-dns: false` + explicit DNS | `templates.tf` | Low | Minor — stabilizes DNS |
| **P5** | Replace 30s fixed sleep | `main.tf` | Low | Prevents spurious apply failures |

---

## Expected Outcome After All Fixes

The first-boot sequence becomes:

```
Time
│
├── 0s: VM boots, ens3 DHCP lease → public IP + default route
├── 5s: ens4 DHCP lease → private IP (NO default route if enable_gateway_ip=false)
│      └── KERNEL HAS ONE DEFAULT ROUTE ← SSH REACHABLE FROM BOOT
│
├── 10s: cloud-init-local.service starts (no netplan apply to disrupt interfaces)
│
├── 15s: sshd starts, accepts connections ← ALWAYS REACHABLE
│
├── 30s: runcmd: ip route del default dev ens4 (safety if enable_gateway_ip=true)
│       └── no network disruption, instant operation
│
├── 35s: k3s-install.sh runs
└── 60s: Terraform reads public IPs, Ansible starts check
```

Key improvements:
- No window where SSH is unreachable
- No interface restarts during cloud-init
- No YAML round-trip corruption
- No hardcoded magic numbers for timing

# OVH Networking Refactor Proposal — Eliminate Runtime `netplan apply`

## Objective

Fix OVH dual-NIC asymmetric routing **without**:

* runtime `netplan apply`
* interface restarts
* SSH race conditions
* `bootcmd` networking mutations
* shell heredocs
* arbitrary sleeps
* fragile YAML round-trips

The solution must:

* preserve the current dual-NIC architecture,
* preserve `enable_gateway_ip = true`,
* preserve DHCP on the private subnet,
* preserve deterministic private IP allocation,
* suppress the private NIC default route from first boot packet.

---

# Root Cause

OVH instances boot with two NICs:

| Interface | Purpose                | DHCP Behavior                                                 |
| --------- | ---------------------- | ------------------------------------------------------------- |
| `ens3`    | Public internet access | Receives correct default route                                |
| `ens4`    | Private subnet         | Also receives a default route when `enable_gateway_ip = true` |

Result:

```text
default via <public-gw>  dev ens3
default via <private-gw> dev ens4
```

Linux may return SSH traffic through `ens4`, causing asymmetric routing and connection timeouts.

The current workaround fixes this by:

1. writing a netplan override,
2. executing `netplan apply` during boot.

But `netplan apply` restarts interfaces and briefly drops `ens3`, making SSH unreliable during first boot.

---

# Architectural Problem

The issue is not the routing rule itself.

The issue is **when and how** the routing fix is applied.

Current behavior:

```text
DHCP configures both NICs
→ invalid routing exists
→ bootcmd mutates networking live
→ netplan apply restarts interfaces
→ SSH races network restart
```

This is inherently nondeterministic.

---

# Proposed Solution

## Use Native Cloud-Init Network Configuration

Do not mutate networking after boot.

Instead:

* inject the final network configuration directly into cloud-init user-data,
* let cloud-init/netplan configure interfaces correctly before networking starts.

Cloud-init already supports native Netplan v2 configuration.

---

# Target Network Configuration

Inject this directly into cloud-init:

```yaml
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

Resulting routing table:

```text
default via <public-gw> dev ens3
<private-cidr> dev ens4
```

No competing default route exists.

---

# Expected Boot Flow

## Current (Broken)

```text
VM boots
  → DHCP configures ens3 + ens4
    → two default routes exist
      → bootcmd runs
        → netplan apply
          → interfaces restart
            → ens3 temporarily disappears
              → SSH becomes unreachable
```

---

## Proposed (Correct)

```text
VM boots
  → cloud-init parses network config
    → netplan generated internally
      → systemd-networkd starts once
        → ens3 gets default route
        → ens4 gets private IP only
          → sshd starts
```

Networking is never restarted during boot.

---

# Required Refactor

## REMOVE

### 1. `bootcmd` networking mutation

Delete:

```hcl
bootcmd = [
  "cat > /etc/netplan/...",
  "netplan apply"
]
```

---

### 2. Runtime shell heredocs

Delete all inline shell-generated netplan logic.

---

### 3. OVH-specific `write_files` netplan persistence

Delete the netplan file injection into:

```hcl
write_files = [...]
```

Cloud-init should own the network lifecycle directly.

---

### 4. Arbitrary sleeps related to networking stabilization

Remove assumptions that networking requires post-boot convergence delays.

---

# IMPLEMENT

## Create Structured Terraform Network Object

Example:

```hcl
locals {
  ovh_network_config = {
    version = 2

    ethernets = {
      ens3 = {
        dhcp4 = true
      }

      ens4 = {
        dhcp4 = true

        dhcp4_overrides = {
          use_routes = false
          use_dns    = true
        }
      }
    }
  }
}
```

---

## Merge Structurally into Cloud-Init

Instead of:

* YAML text surgery,
* shell injection,
* runtime mutation,

perform a structured merge:

```hcl
locals {
  cloudinit_config = merge(
    yamldecode(local.common_cloudinit[name]),
    {
      network = local.ovh_network_config
    }
  )
}
```

Then:

```hcl
user_data = "#cloud-config\n${yamlencode(local.cloudinit_config)}"
```

---

# Preferred Improvement (Recommended)

Avoid Terraform YAML decode/re-encode entirely.

Instead:

* make shared cloud-init templates support an optional `network_config` object.

Example:

## Terraform

```hcl
templatefile(..., {
  network_config = local.ovh_network_config
})
```

## Template

```yaml
%{ if network_config != null }
network:
${indent(2, yamlencode(network_config))}
%{ endif }
```

This is cleaner, safer, and avoids YAML structural mutation in Terraform.

---

# Validation Requirements

Test on:

* Ubuntu 22.04 cloud image
* Ubuntu 24.04 cloud image
* multiple OVH regions
* single-node deployments
* multi-master deployments
* LB-enabled deployments

Validate:

* SSH reachable immediately on first boot
* only one default route exists
* private NIC still receives DHCP private IP
* DNS resolution works
* Kubernetes bootstrap succeeds
* reboots preserve routing correctness

---

# Expected Final State

## Routing

```text
default via <public-gw> dev ens3
<private-cidr> dev ens4
```

---

## SSH

* reachable immediately after first boot,
* no transient disconnects,
* no routing asymmetry.

---

## Kubernetes

* private east-west traffic remains on `ens4`,
* public operator access remains on `ens3`,
* load balancer behavior unchanged.

---

# Benefits

| Improvement                                       | Result                   |
| ------------------------------------------------- | ------------------------ |
| No `netplan apply`                                | No interface restart     |
| No runtime networking mutation                    | No SSH race              |
| Native cloud-init networking                      | Deterministic first boot |
| Simpler Terraform                                 | Easier maintenance       |
| No shell heredocs                                 | Less fragile             |
| No YAML text hacks                                | Safer rendering          |
| Correct routing from first packet                 | Reliable provisioning    |
| Better alignment with Ubuntu cloud-init lifecycle | More future-proof        |

---

# Key Insight

The routing override itself (`use-routes: false`) was already correct.

The real problem was:

* applying it too late,
* and applying it by restarting networking live during boot.

The fix must move from:

* **runtime mutation**
  to:
* **declarative first-boot networking configuration**.

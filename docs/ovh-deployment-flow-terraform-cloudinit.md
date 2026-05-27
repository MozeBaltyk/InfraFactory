# OVH Provider — Deployment Flow: OpenTofu and Cloud-Init through Network Configuration

This document walks through the exact sequence of events when `PROVIDER=OVH ENV=<env> just deploy` runs, from OpenTofu resource creation through cloud-init first-boot to a fully networked node.

---

## Phase 1: OpenTofu Plan and DAG Resolution

Before anything is created, OpenTofu builds a **dependency graph** from the `.tf` files. The OVH provider's resource ordering is:

```
providers.tf (provider config)
  │
  ├── data.ovh_cloud_project_images.all       # discover available OS images
  ├── data.ovh_cloud_project_flavors.all      # discover available flavors
  │
  ├── null_resource.env_directory             # mkdir -p env/OVH/<workspace>/
  ├── tls_private_key.global_key              # RSA 4096 key pair
  ├── random_string.cluster_token             # 32-char cluster token
  │
  ├── ovh_cloud_project_ssh_key.cluster       # upload public key to OVH
  │
  ├── terraform_data.validate_image           # precondition: image found?
  ├── terraform_data.validate_flavors         # precondition: flavors found?
  │
  ├── ovh_cloud_project_network_private       # create private vLAN network
  │     │
  │     └── ovh_cloud_project_network_private_subnet_v2  # subnet on that network
  │           │
  │           ├── null_resource.private_network_destroy_grace  # cleanup hook
  │           │
  │           ├── ovh_cloud_project_instance.vms               # the actual VMs
  │           │     │
  │           │     ├── time_sleep.wait_instance_networks      # 30s delay
  │           │     │     │
  │           │     │     └── data.ovh_cloud_project_instance.vms  # re-read IPs
  │           │     │           │
  │           │     │           └── terraform_data.validate_public_ips
  │           │     │
  │           │     └── local_file.ansible_inventory            # hosts.ini
  │           │
  │           ├── [if LB enabled] data.ovh_cloud_project_loadbalancer_flavors
  │           │     │
  │           │     └── ovh_cloud_project_loadbalancer.kube_api  # LB + gateway + FIP
  │           │
  │           └── local_file.ansible_config                      # ansible.cfg
```

The key detail is that **all VMs depend on the subnet**, and the load balancer depends on both the subnet **and** the VMs (because it references master private IPs that are computed — but the LB resource declaration references the local variable, not the VM resource directly, so OpenTofu may create the LB in parallel with VMs; the `depends_on` in `network.tf` enforces the correct ordering).

---

## Phase 2: Private Network and Subnet Creation

### 2.1 Private Network

```hcl
resource "ovh_cloud_project_network_private" "cluster" {
  service_name = var.ovh_project_service_name
  name         = format("%s-private", var.cluster.id)
  regions      = [var.cluster.region]
}
```

OVH creates a **vLAN-encapsulated layer-2 network** inside the Public Cloud project, isolated to one region. This network is the foundation for all east-west cluster traffic.

### 2.2 Subnet

```hcl
resource "ovh_cloud_project_network_private_subnet_v2" "cluster" {
  network_id = ...
  cidr       = local.private_cidr    # e.g. "10.0.0.0/24"
  dhcp       = true
  enable_gateway_ip               = true
  use_default_public_dns_resolver = true
}
```

This creates an **OpenStack subnet** on the private network with:

| Setting | Purpose |
|---------|---------|
| `dhcp = true` | Enables DHCP on the subnet, so each VM's `ens4` receives an IP automatically |
| `enable_gateway_ip = true` | Creates a gateway IP on the subnet, giving instances on the private network outbound internet access (required for the load balancer's `gateway_create`) |
| `use_default_public_dns_resolver = true` | VMs can resolve external DNS through OVH's infrastructure |

**What this means for routing:** With `enable_gateway_ip = true`, OVH's DHCP server **advertises a default route** on the private NIC. This is the root cause of the asymmetric routing problem that the OVH-specific netplan override must fix (see Phase 4).

---

## Phase 3: VM Creation

### 3.1 Instance Resource Construction

For each master and worker, a single `ovh_cloud_project_instance` resource is created:

```hcl
resource "ovh_cloud_project_instance" "vms" {
  for_each = local.all_vms_map

  service_name   = var.ovh_project_service_name
  region         = var.cluster.region
  billing_period = "hourly"
  name           = each.value.name
  user_data      = local.cloudinit_user_data[each.key]  # ← the full cloud-config
  boot_from      { image_id = ... }
  flavor         { flavor_id = ... }
  ssh_key        { name = ovh_cloud_project_ssh_key.cluster.name }

  network {
    public = true                          # ← public NIC (ens3)

    private {
      ip = each.value.private_ip           # ← pinned private IP

      network {
        id        = local.private_network_id
        subnet_id = local.private_subnet_id
      }
    }
  }
}
```

**What OVH does on its side when this resource is created:**

1. Provisions a VM from the chosen image/flavor in the target region.
2. Creates an **OpenStack port** on the private subnet with the specified IP (DHCP on the subnet reserves this IP for the port).
3. Attaches a **public NIC** (`ens3`) with a dynamically allocated public IPv4.
4. Attaches the **private NIC** (`ens4`) connected to the OpenStack port.
5. Injects the `user_data` (cloud-config) into the instance metadata.
6. Injects the SSH public key (via the `ssh_key` reference to the project key).

**Resulting NIC layout on the VM:**

```
┌──────────────────────────────────────┐
│           OVH Instance               │
│                                      │
│  ens3 (public)                       │
│  ├─ DHCP from OVH public network     │
│  ├─ Public IPv4 (dynamic)            │
│  └─ Default route via OVH gateway    │
│                                      │
│  ens4 (private)                      │
│  ├─ DHCP from private subnet         │
│  ├─ Private IPv4 (pinned by port)    │
│  ├─ Default route (from DHCP!) ──┐   │
│  └─ DNS servers (from DHCP)      │   │
│                                  │   │
│  Problem: TWO default routes!    ◄───┘   │
│  Outbound packets may take ens4,  │   │
│  but inbound SSH comes on ens3    │   │
│  → asymmetric routing → timeout   │   │
└──────────────────────────────────────┘
```

This dual-default-route problem is why the cloud-init generated netplan must strip routes from `ens4`.

### 3.2 Private IP Assignment (Pre-Plan Computation)

Before any resource is created, OpenTofu computes private IPs **at plan time** using `cidrhost()` in `variables.tf`:

```hcl
private_ip_host_offset_base = (
  tonumber(split("/", local.private_cidr)[1]) <= 28 ? 10 : 2
)

# Masters start at offset:
#   cidrhost("10.0.0.0/24", 10 + 0) = 10.0.0.10
#   cidrhost("10.0.0.0/24", 10 + 1) = 10.0.0.11
#   ...

# Workers continue after masters:
#   cidrhost("10.0.0.0/24", 10 + 3 + 0) = 10.0.0.13  (after 3 masters)
#   cidrhost("10.0.0.0/24", 10 + 3 + 1) = 10.0.0.14
```

These computed IPs are used **immediately** in:
- The `network.private.ip` field of each instance (pins the OpenStack port)
- The `current_private_ip` variable passed into cloud-init templates
- The `cluster_join_endpoint` (always = first master's private IP)
- The load balancer backend `members` list (master private IPs)

---

## Phase 4: Cloud-Init User Data Construction (Terraform Side)

This is the most intricate part of the OVH provider. The final `user_data` string passed to each VM is constructed in **three stages** inside `templates.tf`.

### Stage 1: Render the Shared Cloud-Init Template

```hcl
common_cloudinit = {
  for vm in local.all_vms_map :
  vm.name => templatefile(
    "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/cloud_init.cfg.tftpl",
    { hostname = vm.name, current_private_ip = vm.private_ip, ... }
  )
}
```

This takes the provider-agnostic template (e.g., `providers/shared/cloud-init/k3s/cloud_init.cfg.tftpl`) and fills in:
- Hostname, FQDN, domain
- SSH public key
- `current_private_ip` → written into k3s `node-ip` / `advertise-address` or rke2 `node-ip`
- `first_master_ip` → written as `server: https://<ip>:6443` for join nodes
- TLS SANs, k3s/rke2 version, etc.
- Ansible-pull config
- Extra disk config (though disabled for OVH)

**Output:** A YAML string (with `#cloud-config` header) that is a standard cloud-config document.

### Stage 2: Render the OVH-Specific Private NIC Netplan

```hcl
ovh_private_netplan_yaml = templatefile(
  "${path.module}/../shared/cloud-init/${var.cluster.cloud_init_selected}/network_config.cfg.tftpl",
  {
    interface_id         = "privatenic"
    interface_match_name = "ens4"
    use_dhcp           = true
    accept_dhcp_routes = false    # ← KEY: strip default route from DHCP
    accept_dhcp_dns    = true     # keep DNS from DHCP
    ip_address  = ""
    cidr_prefix = ""
    network_gateway = null
    dns_servers     = null
    domain          = ""
  }
)
```

The template (`network_config.cfg.tftpl`) generates this netplan YAML:

```yaml
network:
  version: 2
  ethernets:
    privatenic:
      match:
        name: "ens4"
      dhcp4: true
      dhcp4-overrides:
        use-routes: false      # ← ignore DHCP-supplied default route
        # use-dns is NOT set, so DNS from DHCP is accepted
```

**Why `use-routes: false` but NOT `use-dns: false`:**

- The private subnet's DHCP provides DNS servers through OVH's internal resolver (`use_default_public_dns_resolver = true`). Accepting those DNS servers is harmless and provides a fallback.
- The **default route** from DHCP would make `ens4` compete with `ens3`'s default route, breaking return traffic for inbound SSH connections. That route must be suppressed.

### Stage 3: YAML Merge — Inject Netplan into Cloud-Config

```hcl
cloudinit_user_data = {
  for name, body in local.common_cloudinit :
  name => "#cloud-config\n${yamlencode(merge(
    yamldecode(body),
    {
      bootcmd = [
        "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'\n${chomp(local.ovh_private_netplan_yaml)}\nNETPLANEOF\nnetplan apply",
      ]
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

This is a **Terraform-side YAML merge** that:

1. **Decodes** the Stage 1 cloud-config YAML into a Terraform map.
2. **Merges** two OVH-specific additions into that map:
   - `bootcmd`: adds a command that writes the netplan file and applies it **early** in boot.
   - `write_files`: appends the netplan file to the list of files cloud-init should write.
3. **Re-encodes** the merged map back to YAML with `yamlencode()`.
4. **Prepends** `#cloud-config\n` to produce the final `user_data` string.

**Why both `bootcmd` AND `write_files` for the same file?**

| Mechanism | When it runs | Purpose |
|-----------|-------------|---------|
| `bootcmd` | During `cloud-init-local.service` (very early, before `network.target`) | Applies the netplan immediately via `netplan apply` so the routing fix is active before SSH starts |
| `write_files` | During `cloud-config.service` (later) | Persists the netplan file to disk so it survives reboots (netplan reads from `/etc/netplan/` at every boot) |

Without `bootcmd`, the netplan file would be written but not applied until the next `netplan apply` or reboot — leaving the asymmetric routing problem active during first boot. Without `write_files`, the netplan would be applied transiently but lost on reboot.

---

## Phase 5: What Cloud-Init Does on First Boot

When the OVH instance powers on for the first time, cloud-init processes the merged `user_data` through its standard stages:

### Stage 5.1: `cloud-init-local.service` (networking disabled)

```
[network is still down from initial state]

cloud-init processes:
├── bootcmd:
│   └── "cat > /etc/netplan/99-infrafactory-private.yaml << 'NETPLANEOF'
│         network:
│           version: 2
│           ethernets:
│             privatenic:
│               match:
│                 name: "ens4"
│               dhcp4: true
│               dhcp4-overrides:
│                 use-routes: false
│        NETPLANEOF
│        netplan apply"
│
│   └── netplan apply → netplan generates /run/systemd/network/ configs
│       └── systemd-networkd reconfigures interfaces
│           ├── ens3: DHCP → gets public IP + default route (unchanged)
│           └── ens4: DHCP → gets private IP, BUT no default route (use-routes: false)
│
└── writes meta-data, vendor-data, user-data to /var/lib/cloud/
```

At the end of this stage, the **routing table** is:

```
default via <public-gateway> dev ens3    ← only default route (correct)
<private-cidr> dev ens4 proto kernel     ← direct route to private subnet
```

SSH is **not yet accepting connections** at this point — `ssh.service` hasn't started. This window is safe for the netplan apply transient restart.

### Stage 5.2: `network.target` and network startup

```
systemd starts network.target
├── ens3 now fully up with correct routing
├── ens4 now up with IP from DHCP (the pinned IP from the port reservation)
└── SSH service starts → port 22 open on public IP
```

At this point, the VM is reachable via SSH on its public IP. The asymmetric routing problem is avoided because `ens4` has no default route.

### Stage 5.3: `cloud-config.service`

```
cloud-init executes:
├── manage_etc_hosts: true
│   └── writes /etc/hosts with hostname and FQDN
│
├── users:
│   └── creates <username> with sudo, SSH authorized key
│
├── write_files:
│   ├── /etc/sysctl.d/99-kubernetes.conf       (sysctl tuning)
│   ├── /etc/rancher/k3s/config.yaml           (k3s join config)
│   ├── /usr/local/bin/k3s-install.sh           (install script)
│   └── /etc/netplan/99-infrafactory-private.yaml  ← persists for reboot
│
├── package_update / package_upgrade
│   └── apt update && apt upgrade
│
├── packages:
│   ├── curl, bash-completion, qemu-guest-agent
│   └── extra_packages (if any)
│
└── runcmd:
    ├── systemctl daemon-reload
    ├── systemctl enable qemu-guest-agent
    ├── systemctl start --no-block qemu-guest-agent
    ├── domainname <domain>
    └── /usr/local/bin/k3s-install.sh
```

### Stage 5.4: k3s/rke2 Install Script

The install script runs as a `runcmd` step (or `bootcmd` for rke2, depending on the template):

**First master:**
1. Runs `curl -sfL https://get.k3s.io | sh -s -` with `cluster-init: true` in config.yaml
2. k3s starts, binds to `0.0.0.0:6443` using `node-ip: <private_ip>` and `advertise-address: <private_ip>`
3. The apiserver TLS certificate includes the TLS SANs specified in `config.yaml`

**Secondary master or worker:**
1. Waits for first master's API to be reachable at `<first_master_private_ip>:6443`
2. Then runs the install script with `server: https://<first_master_private_ip>:6443`
3. Joins the cluster using the private network

### Stage 5.5: `cloud-init-final.service`

```
cloud-init marks itself complete:
└── /var/lib/cloud/instance/obj.pkl written
└── cloud-init status --wait returns "done"
```

---

## Phase 6: Post-Boot — Terraform Verifies and Proceeds

Back on the operator machine, after the VMs are created, Terraform continues:

```
time_sleep.wait_instance_networks (30s)
  │ OVH API may take a few seconds to populate public IPs
  │
  ├── data.ovh_cloud_project_instance.vms
  │   └── Re-reads instance data including addresses[] list
  │
  ├── terraform_data.validate_public_ips
  │   └── Precondition: every VM must have a public IPv4
  │       Classification: any address NOT inside private CIDR = public
  │
  ├── local_file.ansible_inventory (hosts.ini)
  │   └── Renders inventory with public IPs
  │
  └── null_resource.check_cloudinit
      └── Ansible: waits until cloud-init --wait returns "done" on every node
```

---

## Timing Diagram

```
Operator                                            OVH Cloud / VM
─────────────────                                    ─────────────────────

Phase 2: create_private_network ─────────────────────► vLAN created
Phase 2: create_subnet        ─────────────────────► subnet + DHCP ready

Phase 3: create_instance(m1)  ─────────────────────► VM boots
                                                      │
                                                      ├─ cloud-init-local
                                                      │   ├─ bootcmd: write + apply netplan
                                                      │   │   └─ netplan apply → ens4 no default route
                                                      │   └─ saves user-data to disk
                                                      │
                                                      ├─ network.target
                                                      │   ├─ ens3 DHCP → public IP + default route
                                                      │   └─ ens4 DHCP → private IP (no route)
                                                      │   └─ sshd starts
                                                      │
                                                      ├─ cloud-config
                                                      │   ├─ write_files (persist netplan)
                                                      │   ├─ create user + SSH key
                                                      │   ├─ apt update/upgrade
                                                      │   ├─ install packages
                                                      │   └─ runcmd: k3s-install.sh
                                                      │       └─ k3s server/agent starts
                                                      │
                                                      └─ cloud-init-final
                                                          └─ cloud-init status → done

Phase 3: create_instance(m2,w1) ───────────────────► parallel VMs boot (same flow)

Phase 6: wait 30s
Phase 6: data source read public IPs ◄────────────── OVH API returns addresses
Phase 6: validate all public IPs exist
Phase 6: generate hosts.ini (public IPs)
Phase 6: check_cloudinit (Ansible) ──────────── SSH ─► cloud-init status --wait
Phase 6: reconciliate_tls (Ansible) ─────────── SSH ─► add TLS SAN, restart kube-apiserver
Phase 6: fetch_kubeconfig (Ansible) ─────────── SSH ─► download /etc/rancher/k3s/k3s.yaml
```

---

## Resulting Network State (After Successful Deploy)

### Routing Table on Each Node

```
default via <public-gateway> dev ens3    ← single default route (correct)
<private-cidr>/24 dev ens4 proto kernel  ← direct route to private subnet
<public-cidr>/?  dev ens3 proto kernel   ← public network direct route
```

### Interface Configuration

| Interface | IP Address | Source | Routes |
|-----------|-----------|--------|--------|
| `ens3` | Public IPv4 (dynamic) | OVH public DHCP | Default via OVH public gateway |
| `ens4` | Private IPv4 (pinned, e.g. `10.0.0.10`) | Subnet DHCP (reserved by port) | Direct route to private CIDR only |

### Netplan File on Disk

Persisted at `/etc/netplan/99-infrafactory-private.yaml`:

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
```

### SSH Access

- Operator connects to **public IP** of any node.
- SSH daemon listens on all interfaces, responds on `ens3`'s public IP.
- Return traffic goes through `ens3`'s default route (the only default route).
- **Asymmetric routing is prevented** because `ens4` has no default route.

### Cluster Internal Traffic

- k3s/rke2 binds to `node-ip: <private_ip>` on `ens4`.
- Kubernetes API server advertises on `<private_ip>:6443`.
- Master-to-master and worker-to-master traffic flows over `ens4` within the private CIDR.
- Load balancer (if enabled) forwards `public_FIP:6443 → master_private_IPs:6443`.

---

## Summary of the Key Insight

The entire OVH network configuration flow is driven by one fundamental constraint:

**OVH instances always have two NICs. The private subnet's DHCP (with `enable_gateway_ip = true`) injects a default route on the private NIC. That default route must be suppressed to avoid breaking SSH.**

The solution is a three-part strategy:

| What | Where | When |
|------|-------|------|
| Render a netplan with `use-routes: false` for `ens4` | `templates.tf` (Terraform side) | Plan time |
| Write + apply netplan via `bootcmd` | Cloud-init user_data (Terraform merge) | `cloud-init-local` (first boot, before SSH) |
| Persist netplan file via `write_files` | Cloud-init user_data (Terraform merge) | `cloud-config` (survives reboot) |

No other provider in InfraFactory needs this workaround because:
- **Libvirt** controls the DHCP server and can disable default route advertisement at the source.
- **Azure** VNets do not inject competing default routes on secondary NICs by default.

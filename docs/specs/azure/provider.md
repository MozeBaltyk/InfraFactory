# Spec — Azure provider

Azure-specific normative spec on top of `../baseline.md`. Distilled from
the Azure sections of `providers/README` (which keeps the descriptive
matrix); on conflict, this file wins.

## 1. Credentials and region

* `azure_subscription_id`, `azure_client_id`, `azure_client_secret`,
  `azure_tenant_id` — secrets from the environment, never committed.
* One region per deployment via `cluster.region` (e.g. `westeurope`).

## 2. Network and addresses

* Subnet derived from `network.cidr` via `cidrsubnet()`; Azure Private
  DNS Zone + A records linked to the VNet from `cluster.domain`.
* Every VM receives a `Standard` SKU static public IP; private IPs are
  Azure-dynamic (no deterministic allocation, unlike OVH).
* Networking is fully ARM-managed: no cloud-init network config is
  rendered for Azure guests.

## 3. Nodes and images

* Hostname prefix from `os_catalog.hostname_prefix` (e.g. `slaz`); naming
  is always role-based — no `cluster.node_name_format` option.
* `ip_type` is always `dhcp`: no static IP option.
* Extra disks use Azure LUN numbering.
* Cloud-init knows both addresses at plan time (`current_private_ip`,
  `current_public_ip`); the public IP is embedded in TLS SANs at install
  time.

## 4. Security

* NSG rules configurable via the `nsg_rules` map (port, name,
  description, source address); defaults cover SSH (22) and K8s API
  (6443). An empty source address is auto-populated from `ifconfig.me`.

## 5. Ansible and artifacts

* Inventory is public-IP based for controllers, workers, and standalone
  `infra.vms`.
* No gitops artifact mode: local files are always written.

## 6. Limitations (normative)

* No OVH-style load balancer; Azure-native constructs only.
* VM-only deployments require `cloud_init_selected = "default"`, no
  workers, and at least one `infra.vms` instance.
* `just replace NAME` targets `azurerm_linux_virtual_machine.vms[NAME]`.

## 7. Acceptance

Baseline §7 for the Azure matrix rows (VM-only `default`, single-master
and HA `k3s`, single-master and HA `rke2`).

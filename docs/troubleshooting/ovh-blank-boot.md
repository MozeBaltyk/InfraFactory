# Blank boot (`DataSourceNone`) — DHCP-era history

Superseded for current code (`config_drive = true` delivers user-data on a
virtual CD-ROM; `dhcp = false` is safe). Kept because the failure is total
and silent, and old workspaces predate the fix.

## Mechanism (then)

`ovh_cloud_project_instance` had no config-drive option, so the guest fetched
`user_data` from the metadata proxy at `169.254.169.254` — which only exists
when Neutron runs a DHCP agent on the subnet (`dhcp = true`). With
`dhcp = false`: no agent → no proxy → cloud-init falls back to
`DataSourceNone`. No user, no key, no IP — a running but blank VM. Even the
private IP itself arrives over that channel, so the NIC stays unconfigured.

Diagnostic tell: private-only nodes died 100% (their only NIC); public nodes
sometimes survived on Ext-Net's own DHCP/metadata.

## If you see it today

It is not DHCP. Check, in order: `config_drive = true` on the instance,
`openstack console log show` datasource lines, and whether user-data changed
without replacement (`ignore_changes = [user_data]` is intended — day-2
drift is Ansible-owned, but a never-booted VM needs its first boot intact).

Synthesized from `.local/network_ovh-backup.md` (removed after dispatch).

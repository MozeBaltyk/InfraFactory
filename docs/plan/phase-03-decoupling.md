# P3 — Cluster decoupling — next

Remove the embedded bastion from `providers/ovh/clusters/` and point the
cluster at the standalone bastion. All in the cluster stack; `bastion/`
untouched.

1. Delete embedded resources from `clusters/bastion.tf` (VM, bastion SG +
   rules, port lookups/associates, readiness check) and `output "bastion"`.
2. New optional input `var.bastion = { public_ip }` (`null` = no jump mode,
   public topology unchanged); derive `lb_ssh_jump_enabled` from it.
   Convention: bastion `username` == cluster `username`.
3. `cluster_ssh_from_bastion`: `remote_group_id` → `remote_ip_prefix`
   (bastion IP on this network from the shared IPAM formula).
4. `ansible.proxy_jump` + `cluster_nodes` output consume the input.
5. Remove gateway/LB `depends_on` bastion (different states now).
6. Update `env/OVH/tfvars.example` (drop the dead `bastion = {}` stub —
   no such variable exists in the cluster stack today — document the new
   `bastion` input). libvirt/Azure untouched.

Gate G3 (offline): `validate` all providers; plan on the jump workspace shows
bastion resources leaving this state while VMs/gateway/LB are unchanged.

Live part (needs approval): state surgery sequencing — imports vs targeted
destroy of the embedded resources without touching the cluster.

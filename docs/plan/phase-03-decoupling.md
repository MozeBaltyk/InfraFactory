# P3 — Cluster decoupling — offline implementation done

Remove the embedded bastion from `providers/ovh/clusters/` and point the
cluster at the standalone bastion. All in the cluster stack; `bastion/`
untouched.

1. Delete embedded resources from `clusters/bastion.tf` (VM, bastion SG +
   rules, port lookups/associates, readiness check) and `output "bastion"`.
2. New optional input `var.bastion = { public_ip }`; Kubernetes is now
   jump-only, while standalone VM behavior remains separate. Convention:
   bastion `username` == cluster `username`.
3. `cluster_ssh_from_bastion`: `remote_group_id` → `remote_ip_prefix`
   (bastion IP on this network from the shared IPAM formula).
4. `ansible.proxy_jump` + `cluster_nodes` output consume the input.
5. Remove gateway/LB `depends_on` bastion (different states now).
6. Update `env/OVH/tfvars.example` (drop the dead `bastion = {}` stub —
   no such variable exists in the cluster stack today — document the new
   `bastion` input). libvirt/Azure untouched.

Gate G3 (offline): implementation is present and all provider validations are
green. No retained authenticated migration plan proves an existing workspace
unchanged, so live acceptance remains in P5.

Migration policy: do not use state surgery. Back up etcd/workloads, save and
review the full authenticated plan, schedule downtime, and treat enabling the
current jump-only topology as a disruptive rebuild. The first controller is
not replaceable until its distribution-specific restore procedure is proven.

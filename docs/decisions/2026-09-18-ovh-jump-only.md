# 2026-09-18 — OVH jump-only Kubernetes (no public topology)

## Context

After the bastion split (P3) the cluster stack still carried both modes:
public Kubernetes nodes when `var.bastion` was null, private-only nodes
when set. The removed `ssh_jump_enabled` flag is silently ignored by
OpenTofu, so a stale tfvars plans public nodes while the operator
believes jump mode is on (proven on `simpl-int-nonprodlike-01`).

## Decision

Kubernetes on OVH is jump-only: k3s/rke2 with masters requires
`var.bastion`, an enabled load balancer, and a `lb_ip`/`dns` endpoint.
All public-node branches (SG rules, public NIC attach, direct Ansible
transport, `public_ip` endpoint) are deleted from the cluster stack, not
deprecated. Plain VM-only deployments are unchanged (dual-NIC standalone
VMs, no bastion needed).

## Consequences

* Pre-existing public Kubernetes workspaces fail fast with a guard
  message instead of planning a downgraded topology; migrating one
  replaces masters/workers (etcd backup, downtime, reviewed saved plan).
* `local.k8s_nodes` replaces every jump conditional; non-Kubernetes
  evaluation paths are byte-identical to before.
* The merged single Nova resource `depends_on` the egress gateway (created
  first, READY before nodes boot); see `main.tf`.

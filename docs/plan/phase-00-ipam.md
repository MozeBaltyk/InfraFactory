# P0 — Shared IPAM contract — done

Extracted the `cidrhost` node allocation and the reserved bastion IP formula
into `providers/shared/modules/ipam` (single source of truth, byte-identical
math). Cluster stack consumes it via `providers/ovh/clusters/ipam.tf`;
bastion stack instantiates it per served cluster.

Added the cluster-side guard: node allocation (`last_node_hostnum`) must stay
below the reserved bastion address (`bastion_hostnum`).

Gate G0 (offline): `tofu validate` green, existing workspaces no-op.
Commit `eb10003`. No behavior change.

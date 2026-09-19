# P0 — Shared IPAM contract — done

Extracted the `cidrhost` node allocation and the reserved bastion IP formula
into `providers/shared/modules/ipam` (single source of truth, byte-identical
math). Cluster stack consumes it via `providers/ovh/clusters/ipam.tf`;
bastion stack instantiates it per served cluster.

Added the cluster-side guard: node allocation (`last_node_hostnum`) must stay
below the reserved bastion address (`bastion_hostnum`).

Gate G0 (offline): validation green; the shared formula is byte-identical and
no behavior change is intended. Commit `eb10003`. No retained authenticated
plan proves existing workspaces no-op; that live evidence is not claimed.

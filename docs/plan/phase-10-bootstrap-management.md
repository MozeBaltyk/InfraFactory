# TO3 — Bootstrap transport and stable endpoints — pending

## Goal

Wire private per-node Talos bootstrap and stable day-2 management without
exposing nodes or coupling Talos to K3s/RKE2 SSH transport.

## Scope

- Build normalized Talos nodes from OVH topology and call the shared
  `talos-cluster` module; cluster code consumes normalized values, not raw
  provider resources where the model suffices.
- Implement the TO0 bootstrap transport with deterministic endpoint allocation,
  readiness, bounded failure, and cleanup. For SSH forwarding, bastion
  `PermitOpen` and cluster SGs admit only the required node TCP/50000 paths;
  K3s/RKE2 TCP/22 behavior remains unchanged.
- Add the selected stable management endpoint, including conditional LB/DNS/SG
  TCP/50000 behavior. Keep Kubernetes TCP/6443 semantics unchanged.
- Pass private node identity as `node_address`, bootstrap transport as each
  node's `endpoint`, management address as `management_endpoint`, and the
  existing LB/DNS API address as `kube_api_endpoint`.
- Skip SSH-key/token artifacts and Ansible in Talos mode; write only applicable
  sensitive artifacts under `env/OVH/<workspace>/`.
- Keep bastion and cluster states independent. Any new bastion input is
  hand-wired by value; no remote-state dependency or state migration.

## Gate TO-G3 — go/no-go

**Go:** offline tests prove unique bootstrap endpoints, least-privilege rules,
stable final endpoints, artifact isolation, and no non-Talos graph changes.
**No-go:** bootstrap depends on a public node NIC, unrestricted TCP/50000,
unbounded background process, shared state, or localhost in final artifacts.
Abort the transport design and return to TO0.

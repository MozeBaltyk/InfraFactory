# ADR-002: Bootstrap Endpoints and Tunnel Non-Persistence

- Status: accepted
- Date: 2026-08-17
- Related: `docs/networking.md`, `docs/architecture.md`

## Context

Talos exposes several addresses that play different roles: the address used
to bootstrap a node, the address used to manage it day-to-day, and the
address the Kubernetes API is reachable on. Early Talos designs conflated
these — for example, using a temporary SSH tunnel as the "management
endpoint" in the generated talosconfig, which broke as soon as the tunnel
was torn down.

## Decision

Treat the following as distinct, never-conflated roles:

```text
node_address        — identity of a node
bootstrap_endpoint  — deterministic per-node access during bootstrap
management_endpoint — stable day-2 access
kubernetes_endpoint — stable Kubernetes API endpoint
```

Rules:

1. A temporary SSH tunnel MUST NOT become the final user-facing Talos
   endpoint. The `talosconfig` `endpoints`/`nodes` must reference the stable
   management endpoint.
2. Per-node bootstrap access is deterministic (resolved per node); day-2
   management uses the stable management endpoint.
3. The Kubernetes API endpoint is resolved once and carried through TLS SAN
   lists and kubeconfig rewriting — never re-derived per node.

## Consequences

### Positive

- Talosconfigs and kubeconfigs remain valid after tunnels and proxies change.
- TLS SAN lists are consistent across controllers and load balancers.
- Node replacement does not change the management/Kubernetes endpoint.

### Negative / Costs

- More endpoint plumbing through locals and module inputs.
- Requires discipline: reviewers must ensure tunnel-based addresses never
  leak into user-facing artifacts.

## Alternatives Considered

- **Allow tunnel addresses as endpoints**: rejected — artifacts become
  ephemeral and break day-2 operations.
- **Single endpoint for everything**: rejected — cannot represent
  private-only clusters behind a bastion/LB.
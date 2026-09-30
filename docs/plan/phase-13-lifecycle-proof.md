# TO6 — Lifecycle, recovery, and security proof — blocked on TO-G5 and approval

## Goal

Promote experimental support to proven by validating HA and day-2 behavior on
new disposable infrastructure.

## Scope

Requires a second explicit paid-cloud approval. Use only a newly named scratch
workspace/network; existing installations remain untouched.

- Deploy the agreed HA shape (at least three control planes plus one worker),
  verify etcd quorum, all nodes Ready, LB TCP/6443, management TCP/50000, and
  workload ingress only if included in the selected design.
- Scale a worker up and down; verify deterministic address and bootstrap-port
  allocation and bastion allowlist convergence.
- Reboot each role and verify installed Talos, network persistence, stable
  endpoints, and artifact usability.
- Replace a worker and a non-bootstrap control plane; verify membership cleanup
  and rejoin. Do not automate first-control-plane replacement until a tested
  Talos etcd backup/restore procedure exists.
- Exercise bastion/transport interruption and recovery; tunnel failure must be
  bounded and final management through the stable endpoint must remain clear.
- Security-check no SSH on Talos nodes, no public node NICs, least-privilege
  SG/LB CIDRs, TLS-authenticated Talos API, protected state/artifacts, and no
  bootstrap endpoint in `talosconfig`.
- Destroy from a healthy state and from the documented recoverable failure
  state; confirm clean provider cleanup. Re-run TO4 no-op comparisons afterward.

Abort and roll back the named scratch deployment on quorum risk, unbounded
replacement, endpoint identity mismatch, widened exposure, orphaned resources,
or any legacy plan diff. No state surgery is an accepted recovery method.

## Gate TO-G6 — go/no-go

**Go:** HA, scale, reboot, allowed replacement, transport recovery, security,
clean destroy, and post-test legacy no-op plans all pass. Support may be called
proven for exactly this tested topology. **No-go:** remain experimental and
publish the unproven lifecycle boundary during closeout.

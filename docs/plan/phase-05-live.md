# P5 — Live validation — partial observations; gates pending approval

Real OVH ops, in order, each a go/no-go. No paid cloud ops without explicit
user approval.

Non-gating evidence already observed: private-node first-boot egress failure
(`35c580b`), jump SSH failing closed before key convergence (`91d3e57`),
unpredictable hot-attached NIC names (`224888f`), and the first-boot DNS race
(`9396746`). These findings informed fixes but do not complete any scenario or
gate below.

1. Bastion-first flow on scratch: bastion `apply` (admin key, no clusters) →
   SSH reachable; cluster keys + network via `ENV=<env> just ovh::bootstrap`;
   bastion attach
   apply → SSH via cluster key, public IP unchanged.
2. Full cluster apply (single-master k3s, jump mode): private-only nodes,
   Ansible via bastion green, single defaults, kubeconfig fetched.
3. Second cluster (new CIDR/vlan): plan = port + attach only, VM untouched,
   public IP stable; keys/`PermitOpen` converged. (This is the deferred live
   proof for P2, including NIC ordering and inline-SG behavior.)
4. HA matrix spot-check: multi-master + workers, `rke2` cloud-init mode.
5. `destroy-vm` → redeploy: same private IPs re-attached, SSH back.
6. Full `destroy` both states: no `409` residue (retry-on-transient-500).

Gate G5: 1–2 green. Gate G6: 3–6 green + `providers/README` matrix
(single-master k3s, HA multi-master + workers, k3s + rke2,
inventory/kubeconfig in `env/OVH/<env>/`).

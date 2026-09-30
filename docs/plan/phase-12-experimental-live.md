# TO5 — Paid scratch first deployment — blocked on explicit approval

## Goal

Establish experimental OVH Talos support on disposable, isolated resources.

## Scope

This phase contains paid and disruptive cloud operations. Execute it only after
TO-G4 and separate explicit user approval naming the scratch workspace, region,
budget, and teardown window. Never reuse or attach to an existing installation.

In order, with a stop between steps:

1. Create a new CIDR/VLAN, new workspace, dedicated image/reference, and
   dedicated bastion attachment or approved transport.
2. Deploy one scratch control plane. From Nova console/runtime evidence verify
   firmware, image, interface, fixed IP, route, DNS, egress, and actual install
   disk before allowing installation.
3. Verify the per-node bootstrap endpoint reaches only that node on TCP/50000;
   apply its machine configuration and observe install plus first reboot.
4. Bootstrap etcd once, fetch `kubeconfig` and `talosconfig`, and confirm both
   use stable management/API endpoints rather than bootstrap tunnels.
5. Verify `talosctl` health and `kubectl get nodes`; capture only redacted
   evidence. Mark support **experimental** at this point, not proven.
6. Destroy the scratch environment and its explicitly owned image resources;
   confirm no orphan ports, FIPs, LBs, gateways, or tunnels.

Abort immediately on an unknown disk/interface, unexpected public NIC, broad
TCP/50000 exposure, loss of management access, install attempt against an
unverified disk, existing-workspace diff, leaked secret, or cost outside the
approved bound. Destroy only the named scratch graph; no rescue by state
surgery or edits to existing environments.

## Gate TO-G5 — go/no-go

**Go:** steps 1–6 pass and clean teardown is proven; OVH Talos may be labeled
experimental. **No-go:** retain no support claim, record the redacted failure,
execute the approved scratch rollback, and return to the owning earlier phase.

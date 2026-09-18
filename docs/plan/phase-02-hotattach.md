# P2 — Hot-attach multi-NIC — done on branch

Per-cluster `openstack_networking_port_v2` (fixed reserved `bastion_ip`) +
`openstack_compute_interface_attach_v2` replaced the inline `network {}`
blocks in `providers/ovh/bastion/main.tf`. Adding a cluster now creates only
a port + attach; the VM (and its public IP) stays. SG declared on the managed
port; the Nova-implicit public port keeps its lookup + associate.
`ignore_changes = [user_data]`, no replace trigger. Netplan was already
per-NIC looped — no template change needed.

Gate G2: `validate` + `fmt` clean. Real-module 0→1→2 planning is
auth-blocked offline, so the proof is a local harness analogue plus the
static argument (VM block takes zero cluster-derived inputs). Live proof
deferred to P5.

Residual risks: parallel attach NIC ordering is best-effort (fails loud via
the guest verify script); SG moved from post-hoc associate to inline on the
port. Both covered by the P5 live test.

Commit `bf06ed5` (plus a 1-line `fmt` fix in `bastion/templates.tf`).

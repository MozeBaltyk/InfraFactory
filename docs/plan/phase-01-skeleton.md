# P1 — Bastion root module skeleton — done

`providers/ovh/bastion/` as an independent root module: VM (Ext-Net only
while `clusters` is empty), `admin_public_keys` bootstrap seed, `clusters`
map default `{}`, `ingress_cidrs`, outputs (`public_ip`, per-cluster private
IPs). Reuses shared cloud-init + netplan/scrub trio. `PermitOpen` omitted
while no cluster is attached; operator connects with a cluster or admin key.
`env/OVH/tfvars.bastion.example` documents `admin_public_keys` + the
`clusters` map. No keys are generated (the `ssh-keys` module is skipped);
the admin pubkey is only registered natively as the Nova keypair Nova
requires, and the readiness probe takes a key-file input. Cluster stack
untouched.

Gate G1 (offline): `init -backend=false` + `validate` green; fixture plan
renders one public-only VM, admin key in user-data, no `PermitOpen`.
Commit `ef59c0e`.

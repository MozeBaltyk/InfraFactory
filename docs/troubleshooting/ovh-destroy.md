# Subnet delete `409` / destroy faults — taxonomy

Three different faults share one symptom. Identify first, then act.
Live SSH/network symptoms live in `../architectures/ovh/03-network.md` §7.

## 1. DHCP-agent orphan ports (old workspaces only)

`dhcp = true` era: Neutron left invisible DHCP ports behind; subnet delete
failed with `409 - One or more ports have an IP allocation`. Fix was
`scripts/ovh-purge-port.sh` (deleted 2026-09-17). With `dhcp = false` that
port class cannot exist. If seen on a pre-config-drive workspace: list ports
on the network and delete the detached ones by hand.

## 2. Transient Neutron IPAM lag (current)

`destroy` hits `409` with zero ports visible and no servers left. Re-running
destroy passes. Not orphan ports — retry before investigating.

## 3. OVH API `500` completing async (current)

Network delete (or FIP create) returns `500`, but retry shows the operation
completed server-side (refresh drops it, state goes to 0 resources). Same
rule: retry before investigating. Instance creation has the sibling lesson:
it waits for the gateway *resource*, not gateway *readiness* — first boots
during gateway churn die on apt/fetch.

Synthesized from `.local/network_ovh-backup.md` (removed after dispatch).

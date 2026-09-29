#!/usr/bin/env bash

# Detect the "Gateway SNAT DOWN" OVH failure without SSHing to a node: check
# the centralized SNAT port status on the cluster's private network. OVH's
# router reports ACTIVE even when this port is DOWN, which is exactly the bug —
# so the router status is not a reliable signal and this port is.
#
# See docs/troubleshooting/ovh-gateway-snat-down.md for the failure and recovery.

set -euo pipefail

if (($# != 1)); then
  printf 'Usage: %s ENV\n' "$0" >&2
  exit 2
fi

environment=$1
project=${PROJECT:-}

if [[ ! $environment =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'ENV must be a nonempty identifier containing only A-Za-z0-9._-\n' >&2
  exit 2
fi

if [[ ! $project =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'PROJECT is required and must contain only A-Za-z0-9._-\n' >&2
  exit 2
fi

command -v openstack >/dev/null 2>&1 || { printf 'Required command not found: openstack\n' >&2; exit 127; }

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# Same precedence as the just recipes: OPENRC override, then project OpenRC.
for f in "${OPENRC:-}" "$root/env/OVH/$project/openrc.sh"; do
  if [[ -n $f && -f $f ]]; then set -a; source "$f"; set +a; break; fi
done

# ovh_cloud_project_network_private name convention: "<cluster-id>-private".
net_name="${environment}-private"
net_id=$(openstack network show "$net_name" -f value -c id 2>/dev/null) || {
  printf 'Network %s not found — deploy the cluster network first.\n' "$net_name" >&2
  exit 1
}

snat_status=$(openstack port list --network "$net_id" \
  --device-owner network:router_centralized_snat -f value -c Status)

if [[ -z $snat_status ]]; then
  printf '%s: no centralized SNAT port (load balancer/gateway disabled — nothing to check).\n' "$net_name"
  exit 0
fi

printf '%s gateway SNAT port: %s\n' "$net_name" "$snat_status"

case "$snat_status" in
  ACTIVE)
    printf 'OK — private-node egress is up.\n'
    exit 0
    ;;
  *)
    printf 'FAIL — SNAT port is %s: private nodes have no internet egress.\n' "$snat_status" >&2
    printf 'Recovery: recreate the gateway (docs/troubleshooting/ovh-gateway-snat-down.md).\n' >&2
    exit 1
    ;;
esac

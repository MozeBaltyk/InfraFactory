#!/usr/bin/env bash
set -euo pipefail

# Sync every project cluster artifact directory to the standalone bastion,
# under /mnt/guests-info/<cluster>/, so the jump host carries each cluster's
# connection artifacts (hosts.ini, ansible.cfg, kubeconfig, keys, token).
#
# Deliberately does not sync project credentials or tfvars.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT=${PROJECT:-}
BASTION_ENV=${BASTION_ENV:-bastion}

[[ $PROJECT =~ ^[A-Za-z0-9._-]+$ ]] || { echo "PROJECT is required and must contain only A-Za-z0-9._-" >&2; exit 2; }
[[ $BASTION_ENV =~ ^[A-Za-z0-9._-]+$ ]] || { echo "BASTION_ENV must contain only A-Za-z0-9._-" >&2; exit 2; }

PROJECT_ROOT="$ROOT/env/OVH/$PROJECT"
CLUSTERS_ROOT="$PROJECT_ROOT/clusters"
BASTION_ROOT="$PROJECT_ROOT/bastion/$BASTION_ENV"

BASTION_KEY="$BASTION_ROOT/.key.private"
BASTION_HOSTS="$BASTION_ROOT/hosts.ini"
BASTION_CFG="$BASTION_ROOT/ansible.cfg"

[ -f "$BASTION_KEY" ] || { echo "bastion private key missing: $BASTION_KEY" >&2; exit 1; }
[ -f "$BASTION_HOSTS" ] || { echo "bastion hosts.ini missing: $BASTION_HOSTS" >&2; exit 1; }

BASTION_IP="$(awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print $1; exit}' "$BASTION_HOSTS")"
BASTION_USER="$(sed -n 's/^remote_user[[:space:]]*=[[:space:]]*//p' "$BASTION_CFG" | head -1)"
BASTION_USER="${BASTION_USER:-localadmin}"

[ -n "$BASTION_IP" ] || { echo "could not resolve bastion IP from $BASTION_HOSTS" >&2; exit 1; }

SSH_OPTS=(-i "$BASTION_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes)

echo "bastion: ${BASTION_USER}@${BASTION_IP}"
# Own the target tree as the bastion user (idempotent); rsync transfers as that
# user, so files must not preserve the local repo's uid (local "ubuntu"=1000 is
# not the bastion operator, localadmin=1001).
ssh "${SSH_OPTS[@]}" "${BASTION_USER}@${BASTION_IP}" "sudo mkdir -p /mnt/guests-info && sudo chown -R '$BASTION_USER' /mnt/guests-info"

shopt -s nullglob
for dir in "$CLUSTERS_ROOT"/*/; do
  name="$(basename "$dir")"
  echo "sync $name -> $BASTION_IP:/mnt/guests-info/$name/"
  rsync -a --no-owner --no-group --delete \
    -e "ssh ${SSH_OPTS[*]}" \
    "$dir" "${BASTION_USER}@${BASTION_IP}:/mnt/guests-info/$name/"
done

echo "done"

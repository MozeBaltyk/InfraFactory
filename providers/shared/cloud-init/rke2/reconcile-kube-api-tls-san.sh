#!/bin/bash
set -euo pipefail

endpoint="${1:-}"

if [ -z "$endpoint" ]; then
  echo "Usage: $0 <endpoint>" >&2
  exit 2
fi

config_path="/etc/rancher/rke2/config.yaml"
service_name="rke2-server"
cert_dir="/var/lib/rancher/rke2/server/tls"

if [ ! -f "$config_path" ]; then
  echo "Config file not found: $config_path" >&2
  exit 1
fi

if grep -Fqx "  - $endpoint" "$config_path"; then
  exit 0
fi

tmp_file="$(mktemp)"
awk -v endpoint="$endpoint" '
  BEGIN {
    in_tls_san = 0
    inserted = 0
    saw_tls_san = 0
  }

  function insert_endpoint() {
    if (!inserted) {
      print "  - " endpoint
      inserted = 1
    }
  }

  {
    if ($0 == "tls-san:") {
      in_tls_san = 1
      saw_tls_san = 1
      print $0
      next
    }

    if (in_tls_san && $0 ~ /^  - /) {
      print $0
      next
    }

    if (in_tls_san) {
      insert_endpoint()
      in_tls_san = 0
    }

    print $0
  }

  END {
    if (in_tls_san) {
      insert_endpoint()
    } else if (!saw_tls_san) {
      print "tls-san:"
      insert_endpoint()
    }
  }
' "$config_path" > "$tmp_file"

mv "$tmp_file" "$config_path"
systemctl stop "$service_name"
rm -f "$cert_dir/serving-kube-apiserver.crt" "$cert_dir/serving-kube-apiserver.key"
systemctl start "$service_name"

deadline="$(($(date +%s) + 120))"
while true; do
  if systemctl is-active --quiet "$service_name" && ss -H -lnt '( sport = :6443 )' | grep -q ':6443'; then
    break
  fi

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "Timed out waiting for $service_name readiness on $(hostname)" >&2
    systemctl status "$service_name" --no-pager || true
    ss -H -lnt '( sport = :6443 )' || true
    exit 1
  fi

  sleep 2
done

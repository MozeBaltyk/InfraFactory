#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d /tmp/opencode/ovh-backend-test.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/providers/ovh/clusters" "$tmp/env/OVH/test" "$tmp/env/OVH/other" "$tmp/env/OVH/local" "$tmp/bin"

cat >"$tmp/bin/tofu" <<'EOF'
#!/usr/bin/env bash
set -eu
for arg in "$@"; do
  case "$arg" in -chdir=*) root=${arg#-chdir=} ;; esac
done
mkdir -p "$TF_DATA_DIR"
: >"$TF_DATA_DIR/terraform.tfstate"
case " $* " in
  *" -migrate-state "*) [[ -z ${TOFU_FAIL_MIGRATE:-} ]] || exit 42 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/tofu"

run_backend() {
  OVH_BACKEND_REPO_ROOT="$tmp" PATH="$tmp/bin:$PATH" "$repo/scripts/ovh/backend.sh" "$@"
}

if run_backend init clusters test s3 >/dev/null 2>&1; then
  echo "missing S3 config was accepted" >&2
  exit 1
fi

cat >"$tmp/env/OVH/test/backend.s3.tfbackend" <<'EOF'
bucket = "test"
region = "gra"
EOF
if run_backend check clusters test s3 >/dev/null 2>&1; then
  echo "uninitialized backend was accepted" >&2
  exit 1
fi
run_backend init clusters test s3 >/dev/null
run_backend check clusters test s3

cp "$tmp/env/OVH/test/backend.s3.tfbackend" "$tmp/env/OVH/other/backend.s3.tfbackend"
run_backend init clusters other s3 >/dev/null
run_backend check clusters other s3

if run_backend init clusters test local >/dev/null 2>&1; then
  echo "unsafe S3 to local switch was accepted" >&2
  exit 1
fi
run_backend init clusters local local >/dev/null
run_backend check clusters local local
run_backend check clusters test s3

# A successful migration replaces the final marker and removes its journal.
cat >"$tmp/env/OVH/local/backend.s3.tfbackend" <<'EOF'
bucket = "test"
region = "gra"
EOF
run_backend migrate clusters local local s3 >/dev/null
grep -qx 'backend=s3' "$tmp/.local/tofu-data/ovh/local/clusters/infra-backend"
test ! -e "$tmp/.local/tofu-data/ovh/local/clusters/infra-backend-migration"
compgen -G "$tmp/.local/backend-backups/*-local-to-s3-*" >/dev/null

# A failed migration keeps the durable journal and every retry refuses.
mkdir -p "$tmp/env/OVH/interrupted"
run_backend init clusters interrupted local >/dev/null
cp "$tmp/env/OVH/test/backend.s3.tfbackend" "$tmp/env/OVH/interrupted/backend.s3.tfbackend"
if TOFU_FAIL_MIGRATE=1 run_backend migrate clusters interrupted local s3 >/dev/null 2>&1; then
  echo "failed migration was accepted" >&2
  exit 1
fi
test -f "$tmp/.local/tofu-data/ovh/interrupted/clusters/infra-backend-migration"
grep -qx 'from=local' "$tmp/.local/tofu-data/ovh/interrupted/clusters/infra-backend-migration"
grep -qx 'to=s3' "$tmp/.local/tofu-data/ovh/interrupted/clusters/infra-backend-migration"
if run_backend migrate clusters interrupted local s3 >/dev/null 2>&1; then
  echo "in-progress migration retry was accepted" >&2
  exit 1
fi

# Bastion shares the same common backend file but must be init'ed independently
# (per-stack key/workspace prefix + TF_DATA_DIR).
mkdir -p "$tmp/providers/ovh/bastion"
run_backend init bastion test s3 >/dev/null
run_backend check bastion test s3
# Still the same project file; clusters remain initialized too.
run_backend check clusters test s3

# Editing the shared config invalidates the recorded fingerprint for both stacks.
cat >>"$tmp/env/OVH/test/backend.s3.tfbackend" <<'EOF'
endpoints = {
  s3 = "https://s3.gra.io.cloud.ovh.net"
}
EOF
if run_backend check clusters test s3 >/dev/null 2>&1; then
  echo "changed S3 config was silently accepted" >&2
  exit 1
fi
if run_backend check bastion test s3 >/dev/null 2>&1; then
  echo "changed S3 config was silently accepted (bastion)" >&2
  exit 1
fi

real="$tmp/real"
mkdir -p "$real/providers/ovh/clusters" "$real/env/OVH/test"
OVH_BACKEND_REPO_ROOT="$real" "$repo/scripts/ovh/backend.sh" init clusters test local >/dev/null
OVH_BACKEND_REPO_ROOT="$real" "$repo/scripts/ovh/backend.sh" check clusters test local
env -u TF_DATA_DIR tofu -chdir="$real/providers/ovh/clusters" init -backend=false >/dev/null
env -u TF_DATA_DIR tofu -chdir="$real/providers/ovh/clusters" validate >/dev/null

echo "ovh-backend tests passed"

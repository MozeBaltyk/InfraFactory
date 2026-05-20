set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

TOFU_RUNNER_IMAGE := env_var_or_default("TOFU_RUNNER_IMAGE", "local.build/tf-runner-libvirt:v0.16.2-homefix")
TOFU_RUNNER_CONTEXT := env_var_or_default("TOFU_RUNNER_CONTEXT", justfile_directory() + "/..")
TOFU_RUNNER_CONTAINERFILE := env_var_or_default("TOFU_RUNNER_CONTAINERFILE", justfile_directory() + "/runner/Containerfile.libvirt")
TOFU_RUNNER_REPOSITORY := env_var_or_default("TOFU_RUNNER_REPOSITORY", "infrafactory/tf-runner-libvirt")
TOFU_RUNNER_TAG := env_var_or_default("TOFU_RUNNER_TAG", "v0.16.2-homefix")
CONTAINER_TOOL := env_var_or_default("CONTAINER_TOOL", "podman")

ZOT_NAMESPACE := env_var_or_default("ZOT_NAMESPACE", "flux-system")
ZOT_SERVICE := env_var_or_default("ZOT_SERVICE", "registry-zot")
ZOT_LOCAL_ADDRESS := env_var_or_default("ZOT_LOCAL_ADDRESS", "127.0.0.1")
ZOT_LOCAL_PORT := env_var_or_default("ZOT_LOCAL_PORT", "5001")
ZOT_SERVICE_PORT := env_var_or_default("ZOT_SERVICE_PORT", "5000")

K3S_REGISTRY_HOST := env_var_or_default("K3S_REGISTRY_HOST", "registry-zot.flux-system.svc.cluster.local:5000")
K3S_SSH_TARGET := env_var_or_default("K3S_SSH_TARGET", "")
K3S_SSH_PORT := env_var_or_default("K3S_SSH_PORT", "22")
K3S_SSH_IDENTITY := env_var_or_default("K3S_SSH_IDENTITY", "")
K3S_SSH_OPTS := env_var_or_default("K3S_SSH_OPTS", "-o BatchMode=yes -o StrictHostKeyChecking=accept-new")
K3S_REMOTE_SUDO := env_var_or_default("K3S_REMOTE_SUDO", "sudo")
K3S_REGISTRY_REMOTE_PATH := env_var_or_default("K3S_REGISTRY_REMOTE_PATH", "/etc/rancher/k3s/registries.yaml")
K3S_RESTART_SERVICE := env_var_or_default("K3S_RESTART_SERVICE", "k3s")
K3S_REGISTRY_INSTALL_CONFIRM := env_var_or_default("K3S_REGISTRY_INSTALL_CONFIRM", "")

[private]
_require-k3s-ssh-target:
    @test -n "{{ K3S_SSH_TARGET }}" || { printf '%s [KO] Missing K3S_SSH_TARGET example %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "ubuntu@192.168.122.10"; exit 1; }

[private]
_require-k3s-registry-install-confirm:
    @test "{{ K3S_REGISTRY_INSTALL_CONFIRM }}" = "yes" || { printf '%s [KO] Refusing remote K3s registry install hint %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "set K3S_REGISTRY_INSTALL_CONFIRM=yes"; exit 1; }

[doc('Build, tag, and push custom tofu runner image through a temporary Zot port-forward')]
publish-forwarded:
    @printf '\n==> Build custom tofu runner image image %s tool %s\n' "{{ TOFU_RUNNER_IMAGE }}" "{{ CONTAINER_TOOL }}"
    @{{ CONTAINER_TOOL }} build -f "{{ TOFU_RUNNER_CONTAINERFILE }}" -t "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_CONTEXT }}"
    @printf '\n==> Publish custom tofu runner image through temporary Zot port-forward local_port %s\n' "{{ ZOT_LOCAL_PORT }}"
    @pf_log="$(mktemp)"; \
      registry_image="localhost:{{ ZOT_LOCAL_PORT }}/{{ TOFU_RUNNER_REPOSITORY }}:{{ TOFU_RUNNER_TAG }}"; \
      kubectl -n "{{ ZOT_NAMESPACE }}" port-forward --address "{{ ZOT_LOCAL_ADDRESS }}" "svc/{{ ZOT_SERVICE }}" "{{ ZOT_LOCAL_PORT }}:{{ ZOT_SERVICE_PORT }}" >"$pf_log" 2>&1 & \
      pf_pid="$!"; \
      cleanup() { kill "$pf_pid" >/dev/null 2>&1 || true; wait "$pf_pid" >/dev/null 2>&1 || true; rm -f "$pf_log"; }; \
      trap cleanup EXIT INT TERM; \
      ready=0; \
      for _ in {1..30}; do \
        if grep -q 'Forwarding from' "$pf_log"; then ready=1; break; fi; \
        if ! kill -0 "$pf_pid" >/dev/null 2>&1; then cat "$pf_log"; exit 1; fi; \
        sleep 1; \
      done; \
      if [ "$ready" -ne 1 ]; then cat "$pf_log"; printf '%s [KO] Timed out waiting for Zot port-forward\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; exit 1; fi; \
      {{ CONTAINER_TOOL }} tag "{{ TOFU_RUNNER_IMAGE }}" "$registry_image"; \
      {{ CONTAINER_TOOL }} push --tls-verify=false "$registry_image"
    @printf '%s [OK] Published custom tofu runner image repository %s tag %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_REPOSITORY }}" "{{ TOFU_RUNNER_TAG }}"

[doc('Render K3s registries.yaml mirror config for the Zot registry')]
k3s-registry-mirror-render:
    @cluster_ip="$(kubectl -n "{{ ZOT_NAMESPACE }}" get svc "{{ ZOT_SERVICE }}" -o jsonpath='{.spec.clusterIP}')"; \
      test -n "$cluster_ip" && test "$cluster_ip" != "None" || { printf '%s [KO] Missing ClusterIP namespace %s service %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ ZOT_NAMESPACE }}" "{{ ZOT_SERVICE }}"; exit 1; }; \
      printf 'mirrors:\n'; \
      printf '  "%s":\n' "{{ K3S_REGISTRY_HOST }}"; \
      printf '    endpoint:\n'; \
      printf '      - "http://%s:%s"\n' "$cluster_ip" "{{ ZOT_SERVICE_PORT }}"

[doc('Install K3s registries.yaml mirror config on a remote VM over SSH')]
k3s-registry-mirror-install-remote: _require-k3s-ssh-target _require-k3s-registry-install-confirm
    @printf '\n==> Install K3s registry mirror config remote %s path %s service %s\n' "{{ K3S_SSH_TARGET }}" "{{ K3S_REGISTRY_REMOTE_PATH }}" "{{ K3S_RESTART_SERVICE }}"
    @identity_arg=""; \
      if [ -n "{{ K3S_SSH_IDENTITY }}" ]; then identity_arg="-i {{ K3S_SSH_IDENTITY }}"; fi; \
      just k3s-registry-mirror-render | \
      ssh -p "{{ K3S_SSH_PORT }}" $identity_arg {{ K3S_SSH_OPTS }} "{{ K3S_SSH_TARGET }}" \
        'set -euo pipefail; tmp="$(mktemp)"; trap "rm -f \"$tmp\"" EXIT; cat > "$tmp"; {{ K3S_REMOTE_SUDO }} install -d -m 0755 /etc/rancher/k3s; if [ -f "{{ K3S_REGISTRY_REMOTE_PATH }}" ]; then {{ K3S_REMOTE_SUDO }} cp -a "{{ K3S_REGISTRY_REMOTE_PATH }}" "{{ K3S_REGISTRY_REMOTE_PATH }}.bak.$(date -u +%Y%m%dT%H%M%SZ)"; fi; {{ K3S_REMOTE_SUDO }} install -m 0644 "$tmp" "{{ K3S_REGISTRY_REMOTE_PATH }}"; {{ K3S_REMOTE_SUDO }} systemctl restart "{{ K3S_RESTART_SERVICE }}"'
    @printf '%s [OK] Installed K3s registry mirror config remote %s path %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ K3S_SSH_TARGET }}" "{{ K3S_REGISTRY_REMOTE_PATH }}"

[doc('Verify remote K3s node status over SSH')]
k3s-registry-mirror-verify-remote: _require-k3s-ssh-target
    @identity_arg=""; \
      if [ -n "{{ K3S_SSH_IDENTITY }}" ]; then identity_arg="-i {{ K3S_SSH_IDENTITY }}"; fi; \
      ssh -p "{{ K3S_SSH_PORT }}" $identity_arg {{ K3S_SSH_OPTS }} "{{ K3S_SSH_TARGET }}" \
        '{{ K3S_REMOTE_SUDO }} k3s kubectl get nodes -o wide'

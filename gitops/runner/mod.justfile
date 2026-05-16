set positional-arguments := true
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

TOFU_RUNNER_IMAGE := env_var_or_default("TOFU_RUNNER_IMAGE", "local.build/tf-runner-libvirt:v0.16.2-homefix")
TOFU_RUNNER_CONTEXT := env_var_or_default("TOFU_RUNNER_CONTEXT", justfile_directory() + "/..")
TOFU_RUNNER_CONTAINERFILE := env_var_or_default("TOFU_RUNNER_CONTAINERFILE", justfile_directory() + "/runner/Containerfile.libvirt")
TOFU_RUNNER_TAR := env_var_or_default("TOFU_RUNNER_TAR", "./tf-runner-libvirt.tar")
TOFU_RUNNER_REGISTRY := env_var_or_default("TOFU_RUNNER_REGISTRY", "localhost:5000")
TOFU_RUNNER_REPOSITORY := env_var_or_default("TOFU_RUNNER_REPOSITORY", "infrafactory/tf-runner-libvirt")
TOFU_RUNNER_TAG := env_var_or_default("TOFU_RUNNER_TAG", "v0.16.2-homefix")
TOFU_RUNNER_REGISTRY_IMAGE := env_var_or_default("TOFU_RUNNER_REGISTRY_IMAGE", TOFU_RUNNER_REGISTRY + "/" + TOFU_RUNNER_REPOSITORY + ":" + TOFU_RUNNER_TAG)
CONTAINER_TOOL := env_var_or_default("CONTAINER_TOOL", "docker")

[private]
_require-runner-tar:
    @test -f "{{ TOFU_RUNNER_TAR }}" || { printf '%s [KO] Missing runner image archive path %s hint %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_TAR }}" "run just runner_image::export first"; exit 1; }

[doc('Build custom tofu-controller runner image')]
build:
    @printf '\n==> Build custom tofu runner image image %s\n' "{{ TOFU_RUNNER_IMAGE }}"
    @{{ CONTAINER_TOOL }} build -f "{{ TOFU_RUNNER_CONTAINERFILE }}" -t "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_CONTEXT }}"
    @printf '%s [OK] Built custom tofu runner image image %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_IMAGE }}"

[doc('Export custom tofu runner image to a tar archive')]
export:
    @printf '\n==> Export custom tofu runner image image %s tar %s\n' "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_TAR }}"
    @{{ CONTAINER_TOOL }} save -o "{{ TOFU_RUNNER_TAR }}" "{{ TOFU_RUNNER_IMAGE }}"
    @printf '%s [OK] Exported custom tofu runner image image %s tar %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_TAR }}"

[doc('Tag custom tofu runner image for the registry')]
tag:
    @printf '\n==> Tag custom tofu runner image for registry src %s dst %s\n' "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"
    @{{ CONTAINER_TOOL }} tag "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"
    @printf '%s [OK] Tagged custom tofu runner image src %s dst %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"

[doc('Push custom tofu runner image to the registry')]
push: tag
    @printf '\n==> Push custom tofu runner image to registry image %s\n' "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"
    @{{ CONTAINER_TOOL }} push "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"
    @printf '%s [OK] Pushed custom tofu runner image image %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_REGISTRY_IMAGE }}"

[doc('Build, tag, and push custom tofu runner image to the registry')]
publish: build push

[doc('Import custom tofu runner image into k3s/containerd')]
import-k3s:
    @printf '\n==> Import custom tofu runner image into k3s image %s tar %s\n' "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_TAR }}"
    @just _require-runner-tar
    @printf '%s [WARN] Import may require elevated permissions depending on k3s setup command %s sudo %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "k3s ctr images import" "not used by this recipe"
    @printf '%s [WARN] Multi-node cluster note action %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "import this image on every node that can run tofu runner pods, or push it to a registry"
    @k3s ctr images import "{{ TOFU_RUNNER_TAR }}"
    @printf '%s [OK] Imported custom tofu runner image into k3s/containerd image %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_IMAGE }}"

[doc('Import custom tofu runner image with ctr into k8s.io namespace')]
import-ctr:
    @printf '\n==> Import custom tofu runner image with ctr image %s tar %s\n' "{{ TOFU_RUNNER_IMAGE }}" "{{ TOFU_RUNNER_TAR }}"
    @just _require-runner-tar
    @printf '%s [WARN] Import may require elevated permissions depending on containerd setup command %s sudo %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "ctr -n k8s.io images import" "not used by this recipe"
    @printf '%s [WARN] Multi-node cluster note action %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "import this image on every node that can run tofu runner pods, or push it to a registry"
    @ctr -n k8s.io images import "{{ TOFU_RUNNER_TAR }}"
    @printf '%s [OK] Imported custom tofu runner image into containerd image %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "{{ TOFU_RUNNER_IMAGE }}"

[doc('Build, export, and import custom tofu runner image into k3s')]
load-k3s: build export import-k3s

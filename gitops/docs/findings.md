# GitOps with FluxCD and tofu-controller

This document summarizes the main findings about the GitOps approach using FluxCD and tofu-controller.

---

## KVM requires a custom runner

The default tofu-controller runner image is not sufficient for the KVM/libvirt provider. KVM deployments need a custom runner image that includes the required libvirt runtime dependencies.

## tfvars are not part of GitOps

Provider tfvars are gitignored and are not managed directly by Flux. They are currently synchronized into the cluster as Kubernetes Secrets through helper recipes, which is a bootstrap mechanism rather than pure GitOps.

## KVM deployment must use remote libvirt

The tofu-controller runner runs as a Kubernetes pod. For KVM, this means `qemu:///system` would target the pod environment, not the host. KVM GitOps deployments must therefore use remote libvirt access, such as `qemu+ssh://...`.

## Terraform must expose artifacts for Secrets

Because tofu-controller runs remotely, Terraform cannot rely on writing artifacts only to local files. The Terraform code needs a GitOps mode that outputs generated artifacts so they can be stored in Kubernetes Secrets.

## Custom runner images must be available to containerd

When using a custom local runner image, that image must be imported into the Kubernetes node runtime, such as containerd, before tofu-controller can schedule runner pods with it.

## A registry may be needed for bootstrap

Instead of manually importing the custom runner image into containerd, the bootstrap process could include access to a container registry. This would make the runner image easier to distribute, especially for multi-node clusters.

## Activation is controlled by provider kustomization

Creating an overlay directory is not enough to make Flux reconcile it. A provider environment becomes active only when it is referenced from `gitops/flux/tf/<PROVIDER>/kustomization.yaml`.

## Flux reconciles committed Git state

Flux does not reconcile local working tree changes. GitOps manifests must be committed, pushed, and then reconciled before the live cluster can reflect them.

## Manifest state and live state can differ

The desired configuration in Git can differ from the Terraform resource currently applied in the cluster. Troubleshooting should compare both the manifest state and the live state, especially for the runner image and Git source.

## tofu-controller needs files in the runner workspace

Files referenced by tofu-controller must exist inside the runner workspace. For tfvars, mapping the Secret to `terraform.auto.tfvars` through `fileMappings` avoids missing path issues inside the pod.

## Bootstrap Secrets must be refreshed manually

Because tfvars and SSH keys are currently synchronized as cluster-local bootstrap Secrets, changing local inputs does not automatically update the cluster. The sync recipes must be run again after changing those files.

## Runner pods are temporary

tofu-controller runner pods are created only during reconciliation and may disappear quickly. Controller logs are often more reliable than looking for a long-running runner pod.

## Runner image recipes live in a module

The custom runner image build and import commands are grouped in `gitops/runner/mod.justfile` and exposed through the `runner_image` module. This keeps image lifecycle tasks separate from Terraform overlay operations.

## KVM has two separate GitOps requirements

KVM GitOps needs both remote libvirt connectivity and a custom runner capable of executing the libvirt provider. Fixing only one of those requirements is not enough.

## Cloud providers need stronger secret handling

For Azure and OVH, GitOps will need an encrypted or external secret workflow before it can be considered complete. Plaintext tfvars and imperative Secret syncs should remain temporary.

Here bootstrap FluxCD with Tofu-controller to deploy k3s/rke2 clusters

### Bootstrap Directories

```sh
📁 bootstrap
├── 📁 apps       # fluxcd in autopilot mode
└── 📁 flux       # flux system configuration
└── 📁 templates  # go template to get values from apps
└── 📄 crds.yaml  # bootstraping with CRDs for fluxCD
└── 📄 flux.yaml  # bootstraping fluxCD
└── 📄 justfile   # command lines
```

### Just commands
```bash
Available recipes:
    bootstrap  # Bootstrap Flux
    delete     # Delete Flux
    forward-ui # Port-forward Flux
```

### Flux Workflow

This is a high-level look how Flux deploys my applications with dependencies. In most cases a `HelmRelease` will depend on other `HelmRelease`'s, in other cases a `Kustomization` will depend on other `Kustomization`'s, and in rare situations an app can depend on a `HelmRelease` and a `Kustomization`.



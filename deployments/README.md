# Deployments

Per-environment and per-federation values consumed by the
`mip-infrastructure` ApplicationSet.

## Audience

> If you're a federation operator looking to **deploy MIP into your own
> cluster**, this repo is **not** the right starting point — it is the
> internal staging configuration of the MIP team. Use the published
> deployment guide instead.
>
> If you're on the MIP team and just landed here, see
> [`../docs/getting-started.md`](../docs/getting-started.md).

## Layout

```
deployments/
├── local/          # Single-cluster deployments (one cluster, many federations)
│   └── federations/<name>/
│       ├── kustomization.yaml         # namePrefix + patches
│       ├── customizations/            # per-fed values overrides
│       └── federation-<name>.yaml     # wrapper Argo CD Application
├── hybrid/         # Multi-cluster deployments (skeleton, in progress)
└── shared-apps/    # Federation-neutral app templates referenced by federations
    ├── exareme2/
    └── mip-stack/
```

The `mip-infrastructure` ApplicationSet auto-discovers each directory under
`local/federations/` and creates the matching wrapper Application.

## Adding or customising a federation

See [`../docs/operations.md`](../docs/operations.md#adding-a-federation).

# MIP Infrastructure

GitOps configuration for the **Medical Informatics Platform (MIP)**: Argo CD
manages the cluster from this repository, with one isolated AppProject per
federation.

> **Just want to deploy MIP?** Read [`deployments/README.md`](deployments/README.md)

## Repo structure

| Path | What it is |
|---|---|
| [`argo-setup/`](argo-setup/) | HA Argo CD install overlay (the controller itself). |
| [`base/`](base/) | The two ApplicationSets that bootstrap everything else, plus out-of-band RBAC. |
| [`projects/`](projects/) | AppProject definitions — static ones and the per-federation Helm template. |
| [`common/`](common/) | Shared charts and manifests (datacatalog, ECK, monitoring, security, submariner, ingress). |
| [`deployments/`](deployments/) | Per-environment / per-federation values (`local/`, `hybrid/`, `shared-apps/`). |
| [`docs/`](docs/) | Architecture, install, operations, troubleshooting, remote-access, and testing docs. |
| [`scripts/`](scripts/) | Helper scripts, including the interactive secrets generator. |

## Documentation list

| I want to… | Read |
|---|---|
| Understand the design and AppProject model | [docs/architecture.md](docs/architecture.md) |
| Install MIP from scratch on a fresh cluster | [docs/getting-started.md](docs/getting-started.md) |
| Add a federation, cluster, or shared app | [docs/operations.md](docs/operations.md) |
| Diagnose a stuck Application or sync error | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Sanity-check a bootstrap or feature branch | [docs/testing.md](docs/testing.md) |
| Reach a cluster from off-network | [docs/remote-access.md](docs/remote-access.md) |
| Bump or re-pin Argo CD | [argo-setup/README.md](argo-setup/README.md) |

## Repository conventions

- **Argo CD namespace:** `argocd-mip-team` (the upstream `argocd` namespace
  is not used).
- **Federation namespaces:** `federation-<name>`.
- **AppProjects:** static ones in [`projects/static/`](projects/static/);
  per-federation projects rendered from
  [`projects/templates/federation/`](projects/templates/federation/).
- **Argo CD version pin:** see [argo-setup/patches/kustomization.yaml](argo-setup/patches/kustomization.yaml).
  Validation guidance lives in [docs/testing.md](docs/testing.md).
- **Pre-commit hook:** install with `git config core.hooksPath .githooks`.
  It enforces the AppProject RBAC lint and the feature-branch revision rule.

## License & acknowledgements

Apache License 2.0 — see [LICENSE](LICENSE).

This project has received funding from the European Union’s Horizon 2020 Framework Partnership Agreement No. 650003 (Human Brain Project), and from the European Union’s Horizon Europe research and innovation programme under Grant Agreement No. 101147319 (EBRAINS 2.0). This work was also supported by the Swiss State Secretariat for Education, Research and Innovation (SERI) under contract No. 23.00638 (EBRAINS 2.0).

## Related projects

- [MIP Stack](https://github.com/Medical-Informatics-Platform/mip)
- [Exareme2](https://github.com/madgik/exareme2) — distributed analytics engine
- [Datacatalog](https://github.com/Medical-Informatics-Platform/datacatalog)

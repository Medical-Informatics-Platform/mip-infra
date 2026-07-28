# tests/e2e — CI-only overlays for the kind e2e pipeline

Everything under this directory exists solely for the e2e workflow
(`.github/workflows/e2e.yml` → `scripts/e2e/run-e2e.sh`). Nothing here is
picked up by the production `mip-infrastructure` ApplicationSet or the
bootstrap manifests — the generators only discover `common/*` (explicit list)
and `deployments/*/federations/*` (from mip-deployments.git).

Two invariants:

- **Committed files keep `targetRevision: main`** (enforced repo-wide by the
  `check-main-revisions` workflow). The e2e runner rewrites `main` to the PR
  head SHA at runtime, in the rendered output only — never in the tree.
- **Overlays change as little as possible.** The point of the e2e run is to
  exercise the production manifests; CI values only shim what a kind cluster
  cannot provide (CephFS RWX storage, MetalLB VIPs, public ingress hosts,
  real Keycloak).

Layout:

- `kind/` — cluster shims applied by every profile (StorageClass aliases) or
  by the haproxy profile (MetalLB address pool).
- `federation/` — kustomize overlay on `deployments/local/federations/federation-A`
  used by the `exareme2` and `mip-stack` profiles.
- `eck/` — CI Application for `common/monitoring/eck` with shrunk resources.
- `datacatalog/` — kustomize overlay on `common/datacatalog`.

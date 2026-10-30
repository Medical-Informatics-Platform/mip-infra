# Notebooks without Kubernetes credentials in the federations

Design and implementation plan for the notebook stack of this platform: where it stands, what the
notebook API proxy changes now, and what it takes to remove the Kubernetes API from the
federation namespaces altogether with a spawn API served by the notebook operator image.

The work spans three repositories: this one (proxy, RBAC, admission policies, network policies,
reconciler), `madgik/mip` (the hub pod in `deployment/kubernetes/templates/jupyterhub.yaml`) and
`mip-jupyter` (the hub image and the operator). Names, paths and values below are the contract
between them.

## 1. Where we are

Each federation runs a JupyterHub (`madgik/mip` chart, `jupyterhub.spawner: operator`). The hub
does not create pods. It creates a `Notebook` object and a token Secret in its own namespace;
the MIP notebook operator in `mip-notebooks-system` turns the `Notebook` into a pod and a home
volume from a `NotebookProfile` the hub cannot edit (`mip-jupyter`, `docs/notebook-operator.md`).

What the hub holds today:

| | Value |
|---|---|
| Identity | ServiceAccount `jupyterhub` in the federation namespace, token projected by the kubelet, valid against the API server |
| RBAC | ClusterRole `mip-jupyterhub`: `notebooks` get/create/delete, `secrets` create; bound per federation by the reconciler (`common/notebook-operator/manifests/reconcile.sh`) |
| Admission | `mip-jupyterhub-secrets`: only Opaque Secrets named `<notebook>-<uid>-token` after their single owner, a Notebook named `jupyter-*`; the CRD rules on Notebook names and env keys |
| Network | egress to the notebook API proxy on 8443 and, while `apiServer.hubDirect` is true, to the control-plane addresses on 6443 (`apiServer.cidrs`) |

The single-user notebook pods have no token (`automountServiceAccountToken: false`) and no API
rule. The exposure is the hub: a user-facing component with an API-valid credential and, with
`hubDirect: true`, the whole API server surface in reach. The RBAC behind the credential is
narrow, so the blast radius is small, but it is not zero: a compromised hub can exercise those
verbs, and it can attack the API server itself.

## 2. Step one, in place here: the notebook API proxy

`common/notebook-operator/manifests/api-proxy.yaml` deploys nginx in `mip-notebooks-system`. The
hub's Kubernetes client is pointed at it instead of the API server. The proxy:

- terminates TLS with a certificate from a private CA issued by cert-manager
  (`api-proxy-certificates.yaml`), read at every handshake so renewals need no restart; the
  CA's public certificate is copied into every federation as ConfigMap `mip-notebooks-ca` by the
  reconciler, which reads it from the CertificateRequest status and never from a Secret;
- forwards the hub's `Authorization` header unchanged, so RBAC and the admission policies of the
  API server remain the authorizers; impersonation headers are blanked;
- allows only the request shapes the spawner uses (Notebook collection: POST; one Notebook: GET
  and DELETE; Secret collection: POST) for namespaces named `federation-*`, matched on the
  normalized path and forwarded as matched, and answers 404 to everything else;
- connects to the API server over TLS verified against the cluster CA; its namespace has no
  external egress.

What it does not change: the hub still holds an API-valid token and the RBAC above. Once
`apiServer.hubDirect` is false, the proxy removes the API server's surface from the federations
and gives one place to audit hub calls. That holds only if the API server is not reachable on
443 at some other address (an external load balancer, for instance): the hub keeps 443 to
anywhere for Keycloak, and its token is valid wherever the API server answers. Check it from the
probe pod in the rollout below. Step two makes the question moot.

Hub side, in the `madgik/mip` chart, behind:

```yaml
jupyterhub:
  apiProxy:
    enabled: true
    host: notebook-api-proxy.mip-notebooks-system.svc.cluster.local
    port: 443
    caConfigMap: mip-notebooks-ca
    tokenExpirationSeconds: 3607
```

which renders on the hub pod:

```yaml
spec:
  automountServiceAccountToken: false
  containers:
    - name: jupyterhub
      env:
        - {name: KUBERNETES_SERVICE_HOST, value: notebook-api-proxy.mip-notebooks-system.svc.cluster.local}
        - {name: KUBERNETES_SERVICE_PORT, value: "443"}
      volumeMounts:
        - {name: kube-api, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
  volumes:
    - name: kube-api
      projected:
        sources:
          - serviceAccountToken: {path: token, expirationSeconds: 3607}
          - configMap: {name: mip-notebooks-ca, items: [{key: ca.crt, path: ca.crt}]}
          - downwardAPI: {items: [{path: namespace, fieldRef: {fieldPath: metadata.namespace}}]}
```

The spawner keeps using `load_incluster_config()`: the kubelet-injected service variables are
overridden by the explicit ones, the client verifies the proxy certificate against the CA file,
and the fully qualified name avoids search-path lookups. Two details decide whether the hub
keeps working after the first hour:

- Token lifetime. The kubelet's own mount asks for exactly 3607 seconds with no audience, and
  the API server extends such tokens to a year; any other value yields a token that really
  expires. Keep 3607 unless the `kubernetes_asyncio` version in the hub image is confirmed to
  re-read the token file, in which case a short lifetime is a gain: a captured token is
  replayable for an hour instead of a year.
- The hub reads the CA file once per client; a CA rotation needs a hub restart.

Most of this carries over to step two (automount off, a projected volume, the CA copy); only
the proxy itself is dropped then.

Rollout order, nothing breaks:

1. this repository (done): proxy, certificates, policies, reconciler; the hubs keep their direct
   path (`apiServer.hubDirect: true`);
2. verify from a federation: a probe pod labelled `app=jupyterhub,component=hub` (the only pods
   the policies let through to the proxy) with a token from `kubectl create token jupyterhub`
   gets an answer from the API server on an allowed path and 404 from the proxy on any other;
   the same token gets no answer from any other address of the API server on 443;
   `kubectl -n federation-<x> get configmap mip-notebooks-ca` shows the CA copy;
3. chart change released; `jupyterhub.apiProxy.enabled: true` in
   `deployments/shared-apps/mip-stack/values.yaml`; spawn a notebook;
4. `apiServer.hubDirect: false` in `common/security/federation/values.yaml`; spawn again.

## 3. Step two, to build: the spawn API

### Goal

No Kubernetes credential and no Kubernetes API in any federation namespace. The hub asks a spawn
API to start and stop servers; the spawn API creates the `Notebook` and the token Secret, and
the operator builds the pod as today. Trust is still anchored in Kubernetes identities, but the
hub's token is bound to the spawn API and rejected by the API server by design.

### Why a separate account, not the controller

The controller's account creates pods in every federation, and whoever creates pods can read
every Secret of the namespace by mounting it. Today that is tolerable because the controller
has no listener. A listener reachable from every hub (and the hub is user-facing) does not
belong in that process. The spawn API is a second mode of the same image (`--mode=spawn-api`),
deployed as its own Deployment with its own ServiceAccount `mip-notebook-spawn-api`, holding
only what it needs: `notebooks` get/create/delete and `secrets` create (confined by the admission
policy), bound per federation, and `tokenreviews` create. The controller keeps its rules and
never gets `secrets` create. A compromised spawn API can start and stop notebooks; it cannot
create a pod.

### Components and flow

```
federation-x                              mip-notebooks-system
hub ── HTTPS, bearer: projected token ──▶ mip-notebook-spawn-api (:8443)
       audience mip-notebook-operator       1. TokenReview(token, audience) -> namespace, account
                                            2. authorize: account == jupyterhub, namespace == path
                                            3. create Notebook + token Secret in that namespace
                                            4. status from the Notebook (phase, url, message)
                                          mip-notebook-operator (controller, unchanged)
                                            Notebook -> pod + home PVC
```

- **Authentication.** The hub mounts a projected token with `audience: mip-notebook-operator`
  (3600 s, rotated by the kubelet; the spawner re-reads the file on every request). The spawn API
  validates it with a `TokenReview` carrying the same audience and requires both
  `status.authenticated` and the audience in `status.audiences`. A token bound to that audience
  is rejected by the API server, so a leaked hub token gives access to the spawn API only, and
  only as that federation.
- **Authorization.** The account must be exactly `system:serviceaccount:{ns}:jupyterhub`, with
  `{ns}` the namespace in the request path, named `federation-*`. Nothing else is accepted.
- **Transport.** TLS with the same private CA as the proxy, distributed as `mip-notebooks-ca`.
  The serving certificate is reloaded from the cert-manager Secret on change. The spawner reads
  the CA file when it changes, so a CA rotation needs no hub restart.
- **API** (JSON over HTTPS at
  `https://mip-notebook-spawn-api.mip-notebooks-system.svc.cluster.local`, versioned path `/v1`,
  errors as `{"error": "..."}`):

| Method and path | Effect |
|---|---|
| `PUT /v1/namespaces/{ns}/servers/{name}` | body: `profile`, `user`, `serverName`, `env`, `apiToken`. Creates the Notebook (annotated `notebooks.mip.ebrains.eu/requested-by`), then its token Secret `{name}-{uid}-token` owned by it; if the Secret fails, the Notebook is deleted. 201 created; 200 when the same Notebook and its Secret exist (a retry); 409 when one exists with another spec or is terminating. Create-only: `Notebook.spec` is immutable, so the hub deletes before it creates, as the spawner does today. |
| `GET /v1/namespaces/{ns}/servers/{name}` | `phase`, `url`, `message`, `deleting` from the Notebook; 404 when gone |
| `DELETE /v1/namespaces/{ns}/servers/{name}` | foreground delete of the Notebook; 202 until gone, then 404 |

  The hub never sees Kubernetes objects. The API token travels once, in the PUT body, over TLS,
  to the component that writes it into the Secret. Status is polled with `GET`, as the spawner
  polls the Notebook today.

Hub environment (`jupyterhub.spawner: operator-api` in the chart):

| Variable | Value |
|---|---|
| `JUPYTERHUB_SPAWNER` | `operator-api` |
| `NOTEBOOK_API_URL` | `https://mip-notebook-spawn-api.mip-notebooks-system.svc.cluster.local` |
| `NOTEBOOK_API_TOKEN_FILE` | `/var/run/secrets/mip-notebook-operator/token` |
| `NOTEBOOK_API_CA_FILE` | `/var/run/secrets/mip-notebook-operator/ca.crt` |

The hub pod has `automountServiceAccountToken: false` and nothing at the standard
ServiceAccount path.

### What it removes

| Today | After |
|---|---|
| ClusterRole `mip-jupyterhub` and its RoleBinding per federation | gone; the reconciler binds `mip-notebook-spawn-api` instead |
| Policy `mip-jupyterhub-secrets` on the hub account | matches the spawn API account: same rule, one subject |
| Hub egress to the proxy and, with `hubDirect`, to 6443 | one rule: hub to the spawn API on 8443 |
| Notebook API proxy: Deployment, Service, nginx template and serving certificate | gone; the private CA, its issuer and the CA distribution stay for the spawn API's serving certificate |
| Hub `ServiceAccount` token valid against the API server | projected token with audience `mip-notebook-operator`, 3600 s, useless elsewhere |

### What it adds

| Where | Addition |
|---|---|
| `mip-jupyter` operator | `--mode=spawn-api`: HTTPS server on 8443, `TokenReview` client, the handlers above, an uncached client (RBAC limits it to bound namespaces), per-namespace rate limit, metrics for requests and denials; the controller mode is unchanged |
| `mip-jupyter` hub image | spawner mode `operator-api`: `start()` DELETEs and waits, PUTs and polls `GET`, `stop()` DELETEs, `poll()` maps phases; tornado's HTTP client, no Kubernetes client |
| `madgik/mip` chart | `jupyterhub.spawner: operator-api` and `jupyterhub.operatorApi` (url, audience, caConfigMap, tokenExpirationSeconds); no Role in that mode |
| `base/mip-infrastructure/notebook-operator/rbac.yaml` | ServiceAccount and ClusterRole `mip-notebook-spawn-api` (bound per federation by the reconciler); ClusterRole `tokenreviews` create with a ClusterRoleBinding; the reconciler may bind the new role; the Secret policy matches the spawn API account (and the hub, during the migration) |
| `common/notebook-operator/manifests` | spawn API Deployment (two replicas), Service 443 to 8443, Certificate from the existing CA issuer; the reconciler reads the CA from that certificate |
| `common/security` | spawn API: egress to 6443, ingress from federation hubs on 8443; the hub rule targets it; `hubDirect` is removed |
| per-federation `customizations/mip-stack-values.yaml` | the new spawner mode, one federation at a time |
| `scripts/kind-argo-test.sh` | the spawn API account creates Notebooks and Secrets only where bound and never pods; a token with the spawn API audience is refused by the API server |

### Security review of the target

- The spawn API becomes the only holder of `secrets create` and `notebooks create` in the
  federations, confined by the same admission policy that confines the hub today. It cannot
  create pods; the controller, which can, has no listener.
- A compromised hub can start and stop servers of its own federation through the spawn API,
  which is exactly what it can do today, minus the API server and minus any Kubernetes
  credential.
- The spawn API rate-limits per namespace and logs every denied request; a hub that floods it
  must not starve the others.
- `TokenReview` costs one API call per hub request. Positive results are cached for at most 60
  seconds: the hub token is bound to its pod and dies with it, so a cache for the token's
  lifetime would keep a deleted pod's token valid for up to an hour.
- The API server audit log shows the spawn API account instead of the hub; the
  `requested-by` annotation and the spawn API's own log keep the attribution.

### Migration

1. Operator and hub images with the new modes released; chart released with the values.
2. Apply the new `rbac.yaml` (spawn API account and role, the TokenReview binding, the Secret
   policy matching both accounts; the hub ClusterRole stays until step 5).
3. Merge the manifests: the spawn API runs next to the proxy; network policies admit both.
4. Set `jupyterhub.spawner: operator-api` per federation (one at a time), spawn, stop, restart
   the hub with a server running. Notebooks created by the hub and by the spawn API are the
   same objects, so nothing is migrated.
5. Remove the hub ClusterRole, its RoleBindings and its subject in the Secret policy; point the
   hub rule at the spawn API only; remove the proxy manifests, the nginx template and
   `hubDirect`.
6. `kubectl auth can-i create notebooks.notebooks.mip.ebrains.eu --as=system:serviceaccount:<ns>:jupyterhub -n <ns>`
   answers `no` in every federation; a spawn still works.

### Open questions

- Audit: decide where the spawn API's log is shipped (the current log pipeline keeps only
  federation namespaces).
- Whether the spawn API should also serve the hub's `/api/platform-token` needs is out of scope;
  that path does not touch Kubernetes.

## 4. Test plan for both steps

- Render: `kustomize build common/notebook-operator/manifests`, `helm template` of both security
  charts with `hubDirect` true and false.
- Kind smoke test (`scripts/kind-argo-test.sh`): reconciler bindings and CA ConfigMap only in
  labelled `federation-*` namespaces, admission policies refusing every other write, the Argo CD
  controller without RBAC write, the hub without `pods` create.
- Proxy: nginx configuration checked in CI; on the cluster, a probe pod with the hub token calls
  an allowed path and a refused path through the proxy.
- Spawn API (step two): unit tests on authentication and authorization (wrong audience, wrong
  namespace, wrong account), an envtest spawn, and the staging sequence of the migration above.

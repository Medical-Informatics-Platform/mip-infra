# Network policies

This directory isolates the namespaces of the cluster. Every federation namespace and every common namespace gets a default deny with explicit allows. A Calico tier confines the traffic of the remote nodes of hybrid federations.

| Path | Content |
| --- | --- |
| `netpol.yaml` | The ApplicationSets and Applications that deploy the charts below |
| `federation/` | Chart for federation namespaces |
| `common-templates/` | Chart for common namespaces |
| `remote-clusters/` | Calico tier `remote-clusters` and its end-of-tier policy |
| `remote-networks/` | Chart for the policy of one hybrid federation in that tier |
| `diagram.svg` | Overview |

![Network policies](diagram.svg)

## Federation namespaces

The ApplicationSet `federation-network-policies` finds every federation (`deployments/local/federations/*`, `deployments/hybrid/federations/*/mip-infrastructure`) and applies the chart `federation/` to its namespace.

| Direction | Allowed |
| --- | --- |
| Ingress | the same namespace; the Argo CD namespace `argocd-mip-team` |
| Egress | the same namespace; DNS in `kube-system` (UDP and TCP 53); HTTP (80) and HTTPS (443) anywhere |

Notebook pods (`component: singleuser-server`) do not get these rules. Their own policies (`federation/templates/notebook-network-policy.yaml`) allow the same namespace, DNS and the Jupyter AI proxy, but no internet. A NetworkPolicy can only add access, so leaving them out is the only way to take the internet away. User code and the shared examples run next to the user's platform token and cannot send it out directly. `%pip install` and other downloads fail. DNS still resolves outside names.

## Common namespaces

The ApplicationSet `common-network-policies` (`netpol.yaml`) applies the chart `common-templates/` to each listed namespace: `mip-common-datacatalog`, `mip-athena` (Jupyter AI proxy) and `mip-notebooks-system` (notebook operator).

| Direction | Allowed |
| --- | --- |
| Ingress | the same namespace; Argo CD; federations, only where enabled (below) |
| Egress | the same namespace; DNS; HTTP and HTTPS |

Some namespaces need more, in `common-templates/templates/common-network-policies.yaml`:

- `mip-athena` admits only federation notebook pods, and only `athena-proxy` reaches the inference server (`athenaProxy.upstream` in `common-templates/values.yaml`).
- `mip-notebooks-system`: the operator and the RBAC reconciler reach the API server on 6443, the hub pods of the federations reach the notebook API proxy on 8443, and the proxy reaches the API server. The namespace has no HTTP or HTTPS egress (`networkPolicy.noExternalEgress`).

### Federation access to common namespaces

Federations reach common namespaces only where `federationAccess` in `common-templates/values.yaml` allows it. It is set per federation type, read from the namespace label `mip.federation-type`, and off by default:

```yaml
federationAccess:
  local:
    enabled: true
    allowedCommonNamespaces:
      - mip-common-datacatalog
  hybrid:
    enabled: false
    allowedCommonNamespaces: []
```

### API server egress (`apiServer.cidrs`)

JupyterHub pods, the notebook operator and its RBAC reconciler talk to the Kubernetes API. Policies are evaluated after the `kubernetes` Service DNAT, so the egress rules on TCP 6443 see the control-plane node addresses. `apiServer.cidrs` limits these rules to the listed addresses; an empty list admits any address on 6443.

- Keep the list equal in `federation/values.yaml` and `common-templates/values.yaml` (CI compares them). The chart `remote-networks/` lists the same addresses in `centralNetworks`.
- Update it when the control-plane nodes change. `check-central.sh` fails when a live endpoint is not in the list. Read the addresses:

  ```bash
  kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}/32{"\n"}{end}'
  ```

The hub may always reach the notebook API proxy on 8443. `apiServer.hubDirect` in `federation/values.yaml` also keeps its direct rule to 6443; set it to `false` once every hub uses the proxy. The policy keeps its name either way, so Argo CD updates it in place.

## Remote clusters (Submariner)

Hybrid federations get the same default deny as local ones. The flows they need with their remote nodes are allowed per component and port in the federation's own `submariner-policies/`, with one `ipBlock` per remote pod CIDR. Design: [docs/hybrid-federations.md](../../docs/hybrid-federations.md).

The Calico tier `remote-clusters` adds a cluster-wide guard. Calico evaluates it (order 500) before every Kubernetes NetworkPolicy. It needs Calico 3.29 or later (`kubectl get tiers.projectcalico.org` lists `default`).

- `remote-networks/` builds one policy per hybrid federation, `remote-clusters.<namespace>`. It passes two flows to the federation's NetworkPolicies: remote workers to the aggregation server, and the controller to the remote workers. It denies every other flow from or to the federation's remote networks, in every namespace. The namespace is matched by `kubernetes.io/metadata.name`. The controller's HTTP API and the Flower server are closed to remote networks, and other federations are closed like any other namespace.
- The last policy of the tier, `remote-clusters.pass-other-traffic`, passes all other traffic on to the Kubernetes NetworkPolicies.
- The Deny rules apply to every pod. The chart therefore refuses a file without the `remoteNodes` list, a network wider than `/16`, and a network that overlaps a network of this cluster (`centralNetworks`: pod and service networks, API server addresses). A refused file leaves its Application in error and the last synced policy in place.
- The ApplicationSet `federation-remote-networks` reads `deployments/hybrid/federations/*/mip-infrastructure/remote-networks.yaml`; the namespace is the directory name. Nothing under `common/` names a federation or a network.
- The Application `netpol-remote-clusters` syncs the tier, and `netpol-<namespace>-remote` each federation policy. Both are in the project `mip-argo-project-security`, which allows `Tier` and `GlobalNetworkPolicy`. The Argo CD application controller may write only policies named `remote-clusters.*`.

To add a remote node, put its pod CIDR into the federation's `submariner-policies/network-policy.yaml`, and its pod and service CIDR into the federation's `remote-networks.yaml`. Nothing under `common/` changes, not even for a new hybrid federation. `scripts/check-remote-cidrs.sh` (CI, needs `yq` and `helm`) checks that:

- both files agree with the node's `submariner-values*.yaml`;
- no network overlaps another one or a network of this cluster;
- `centralNetworks` covers the networks of this cluster, and the chart refuses an overlapping network and a file without `remoteNodes`;
- the rendered policy passes the networks to the federation's namespace only.

Migration: the earlier shared policy `remote-clusters.confine-remote-clusters` is not pruned. While it exists it decides first, and the federation policies have no effect; `check-central.sh` warns. Delete it once `check-central.sh` reports the federation's policy as correct:

```bash
kubectl delete globalnetworkpolicies.projectcalico.org remote-clusters.confine-remote-clusters
```

## Add a namespace

- Federation: create its directory, `deployments/local/federations/<name>/` or `deployments/hybrid/federations/<name>/mip-infrastructure/`. The ApplicationSet applies the policies.
- Common namespace: add it to the list of the `common-network-policies` ApplicationSet in `netpol.yaml`, and to `federationAccess` if federations need it.

## Deployment

The `mip-infrastructure` ApplicationSet deploys this directory. The ApplicationSets in `netpol.yaml` create one Application per namespace; list them with `argocd app list | grep netpol-`. To deploy by hand: `kubectl apply -f common/security/netpol.yaml`.

The policy Applications do not prune. A policy removed from git stays on the cluster until you delete it.

## Troubleshooting

1. List the policies of the namespace: `kubectl -n <namespace> get networkpolicies`.
2. Check the labels of a federation namespace: `kubectl get namespace <namespace> --show-labels`. The policies of the common namespaces select federations by `mip.namespace-type` and `mip.federation-type`; the network-policy Applications set both.
3. Test DNS from the namespace: `kubectl -n <namespace> run test-dns --image=busybox --rm -it -- nslookup kubernetes.default`.

## Known limits

- **Notebook examples are reviewed code.** `notebook-examples-sync` (`deployments/shared-apps/mip-stack/notebook-examples`, one per federation) serves only the mip-examples commit pinned in `EXAMPLES_REVISION`. mip-examples takes changes only through reviewed pull requests, and Renovate moves the pin through a pull request here. Review the compare link of that pull request like code: the examples run in users' notebooks next to their platform token. The sync pod uses the federation's 80/443 egress, has no service-account token and mounts only the examples volume, which notebooks mount read-only.
- **The worker isolation policies match no pod.** `federation/templates/exareme-network-policy.yaml` still selects the old labels `app: exareme2-*`. Re-enabling it needs corrected selectors and complete rules: controller to worker 5672, worker to aggregation server 50051, worker to controller 5000, worker DNS, local worker to global worker 8080. It also needs the `excludedSelector` parameter in `netpol.yaml`, and it changes local federations as well.

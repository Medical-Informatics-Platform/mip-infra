# Hybrid federations

A hybrid federation runs its controller, aggregation server and MIP stack on the central cluster, and its Exareme2 (exaflow) workers on remote nodes: one single-node MicroK8s cluster per site. Submariner connects the clusters. A local federation runs everything on the central cluster (`deployments/local/`); hybrid federations are in `deployments/hybrid/`.

## Layout

```
central cluster (RKE2)                          remote node (MicroK8s)
  federation-z namespace                          federation-z namespace
    exaflow-controller  ---- gRPC 5672 ---->        exaflow-localworker
    exaflow-aggregation <--- gRPC 50051 ---         (site data)
    mip-stack
  submariner-operator: gateway (LoadBalancer)  <== IPsec / NAT-T ==  submariner-operator: gateway
  submariner-k8s-broker: broker (API server)   <-- TCP 6443 -------  operator, Lighthouse agent
```

- The remote node opens the tunnel. The central gateway answers on UDP 4500 (NAT-T) and UDP 4490 (NAT discovery) at its LoadBalancer address. Remote nodes exchange IPsec with that address only.
- The clusters route each other's pod and service CIDRs. Network policies decide which flows pass.
- Lighthouse publishes exported Services as `<service>.<namespace>.svc.clusterset.local` in every cluster.

## Central cluster

Argo CD manages everything except the files in `base/mip-infrastructure/rbac/`, which you apply by hand, and the enrollment objects.

| Piece | Path | Role |
| --- | --- | --- |
| Operator | `common/submariner/` | Submariner operator chart and its Application. The operator also installs the broker CRDs. The broker is the namespace `submariner-k8s-broker`. |
| Out-of-band RBAC | `base/mip-infrastructure/rbac/submariner-rbac.yaml` | Namespaces, the roles the Argo CD project may not create, the route watchdog's admission policy |
| Broker accounts and policies | `base/mip-infrastructure/rbac/submariner-remote-admission.yaml` | Role of the remote clusters and four admission policies |
| Broker credentials | `common/submariner/operator/broker-credentials.yaml` | The operator's own broker account; Kubernetes fills its token Secret |
| IPsec PSK | Secret `submariner-ipsec-psk` in `submariner-operator` | Created once by hand, never in git |
| Enrollment scripts | `deployments/hybrid/federations/federation-Z/enrollment/` | `enroll-remote.sh`, `verify-enrollment.sh`, `revoke-remote.sh`, `check-central.sh` |
| Federation | `deployments/hybrid/federations/federation-Z/mip-infrastructure/` | Exareme2 and the MIP stack in `federation-z`, found by the ApplicationSets. `federation-z.yaml` is a wrapper Application for manual bootstrap only. |
| Worker discovery | `.../customizations/exareme2-values.yaml` | `controller.workers_dns`: the local worker Service and the clusterset name of the remote workers |
| Remote flows | `.../submariner-policies/` | NetworkPolicies per component and port, and the ServiceExport of the aggregation server |
| Remote networks | `.../remote-networks.yaml` | Pod and service CIDR of each remote node; input of the federation's Calico policy |
| Remote-cluster tier | `common/security/remote-clusters/`, `common/security/remote-networks/` | Calico tier and the chart of each federation's policy |

Two prerequisites belong to the cluster installation, not to this repository. Check both after a node redeploy:

- One worker node carries the label `submariner.io/gateway=true`. The gateway runs there, and MetalLB announces the gateway address from it. If the label is missing, run `kubectl label node <worker> submariner.io/gateway=true` and tell the provider.
- The Calico API server serves `projectcalico.org/v3` (`kubectl get apiservice v3.projectcalico.org`). The operator, the route agents and the Calico tier need it. A broken one shows `stale GroupVersion discovery: projectcalico.org/v3` in the operator log. One known cause: the `calico-apiserver` account may not list ConfigMaps cluster-wide.

Run `enrollment/check-central.sh` before every join and after every change. It only reads, and sends server-side dry runs. It covers the gateway and its routing, the watchdogs, Calico, the broker and its credentials, cluster DNS, the exports, the admission policies, every enrollment and the network policies.

## Remote nodes

Argo CD does not manage remote nodes. Follow the runbook: [`remote-node/README.md`](../deployments/hybrid/federations/federation-Z/remote-node/README.md).

| Script | Does |
| --- | --- |
| `reset-node.sh` | Cleans a node that carries an earlier attempt |
| `preflight.sh` | Checks before the install, before the join, and on a joined node (`--stage health`) |
| `setup-tools.sh` | Base packages, and `subctl` at the Submariner version |
| `setup-microk8s.sh` | MicroK8s with the node's CIDRs and RBAC, Calico API server, route watchdog, IPsec firewall, gateway label |
| `join-submariner.sh` | Installs the Submariner operator chart with the enrolled identity |
| `deploy-worker.sh` | The exaflow worker, its Service, ServiceExport and NetworkPolicy |

The real broker address is in the per-node values files `remote-node/submariner-values*.yaml`. Credential files and the cluster ID are never committed.

The node installs the operator chart with Helm. `subctl join` needs a `broker-info.subm` file and a PSK in the `Submariner` resource, and this setup has neither. `subctl` is still installed, at the same version, for `show`, `diagnose` and `uninstall`.

## Credentials of a remote node

Enrollment gives the node a cluster ID and three values. Their encodings differ: a wrong CA gives `x509` errors, a wrong PSK a tunnel that never authenticates.

| Value | Source on the central cluster | Passed to the chart as |
| --- | --- | --- |
| Token | `kubectl create token cluster-<id>` (bound, with an expiry) | plain text |
| CA | ConfigMap `kube-root-ca.crt` | base64 |
| PSK | `.data.psk` of the Secret `submariner-ipsec-psk` | base64, exactly as stored |

The central gateway reads the PSK from the mounted Secret and base64-encodes it. A remote node uses the Helm value as it is. Both sides therefore use the stored base64 string.

The cluster ID (`rn-<8 hex>` by default) is chosen at enrollment. It becomes the node's Submariner cluster ID and worker identifier. Keep the mapping from ID to site in the internal tracking system.

## Broker accounts and admission policies

Two kinds of accounts write to the broker namespace `submariner-k8s-broker`:

- `submariner-operator/submariner-broker-client`, used only by the central operator. Its Role may read Secrets in the broker namespace, because the operator's broker secret syncer needs it. Keep no Secret there; `check-central.sh` fails if one appears.
- `cluster-<id>`, one per remote node, created by `enroll-remote.sh`. Its Role `submariner-remote-cluster` has no access to Secrets or ServiceAccounts. Four admission policies limit it:

| Policy | Rule |
| --- | --- |
| `submariner-remote-cluster-ownership` | The account writes only objects with its own cluster ID: Cluster and Endpoint by `spec.cluster_id` and name, EndpointSlice and per-cluster ServiceImport by label, aggregated ServiceImport by its entry in `status.clusters`. A new aggregated ServiceImport is named `<service>-<namespace>`, and a clusterset IP names its allocator. Only the last exporting cluster deletes an aggregated ServiceImport. |
| `submariner-remote-cluster-subnets` | Endpoint subnets lie within the CIDRs of the enrollment record. |
| `submariner-remote-cluster-exports` | Lighthouse objects publish only the services of the enrollment record. |
| `submariner-remote-cluster-records` | No service account writes an enrollment record; people do, with the enrollment scripts. |

The enrollment record is the ConfigMap `cluster-<id>` in the broker namespace. It holds `subnets` and `exports` (comma-separated `<namespace>/<service>`). By default a node may export the worker Service of its federation; a record without `exports` allows no export. To change the exports:

```bash
kubectl -n submariner-k8s-broker patch configmap cluster-<id> --type merge \
  -p '{"data":{"exports":"<namespace>/<service>,<namespace>/<service>"}}'
./verify-enrollment.sh CLUSTER_ID=<id> IMPERSONATE=true
```

Remove an export from the record only after the node has withdrawn it. Otherwise the broker refuses the node's update that takes it out of the shared import, and you remove the node from that import by hand.

`revoke-remote.sh` deletes the account, which invalidates all its tokens, and the node's broker objects.

Whoever holds a node's token and the PSK can act as that node, within its enrolled subnets and exports. The network policies limit what such a node reaches.

## Network policies

Hybrid federation namespaces get the same default deny as local ones. Two flows with remote nodes are allowed per component in `submariner-policies/network-policy.yaml`:

| Flow | On the central cluster | Port |
| --- | --- | --- |
| Controller to remote workers (gRPC tasks) | egress from `app=exaflow-controller` | TCP 5672 |
| Remote workers to the aggregation server | ingress to `app=exaflow-aggregation-server` | TCP 50051 |

Remote nodes reach nothing else. The controller's HTTP API (TCP 5000) has no authentication and starts computations, so it is closed, and the controller is not exported. The Flower server (TCP 8080) is closed as well. Flower algorithms therefore cannot use datasets on remote nodes.

The rules list pod CIDRs only. The controller dials remote pod addresses (the worker Service is headless), and remote pods keep their own source address towards central services.

The Calico tier `remote-clusters` (order 500) is evaluated before every Kubernetes NetworkPolicy. It also protects the namespaces that have no policies of their own:

- Each hybrid federation has one policy in it, `remote-clusters.<namespace>`, built by the chart `common/security/remote-networks` from the federation's `remote-networks.yaml`. The policy passes the two flows above to the federation's NetworkPolicies and denies every other flow from or to the federation's remote networks, in every namespace.
- The policy matches the namespace by `kubernetes.io/metadata.name`, which only the API server sets. A remote node never reaches another federation. A node that serves two federations needs a separate address range for each.
- The last policy of the tier, `remote-clusters.pass-other-traffic`, passes all other traffic on.
- The ApplicationSet `federation-remote-networks` creates one Application per file, `netpol-<namespace>-remote`. Keep `remote-networks.yaml` in this repository: it decides deny rules for every pod.
- The chart refuses a file without the `remoteNodes` list, and any network wider than `/16`, outside the private ranges (RFC 1918), or overlapping a private network of this cluster (`centralNetworks`: pod and service networks). A refused file leaves its Application in error and the last synced policy in place. No remote network can cover the public addresses of this cluster, such as the API server and the nodes. This holds only while they are public: if a node or API server address becomes private, add it to `centralNetworks`. `check-central.sh` fails until you do.
- A removed file leaves its policy on the cluster until you delete it.

`scripts/check-remote-cidrs.sh` (CI) checks that the node values files, `remote-networks.yaml` and the NetworkPolicies agree, that no network overlaps another, and that the chart refuses bad input. `check-central.sh` checks the policies on the cluster.

Remote pods can reach the Kubernetes API service address. It ends on the host, where no workload policy applies; only authentication protects it.

## Add a remote node

1. In the repository: add the node's pod CIDR as an `ipBlock` to every rule of `submariner-policies/network-policy.yaml`, add an entry with its pod and service CIDR to `remote-networks.yaml`, and add its values file `remote-node/submariner-values-<node>.yaml`. CI checks that the three agree.
2. Merge, and let Argo CD sync the federation's policies.
3. Follow the runbook: enroll, set up, join, deploy the worker.

Give every node its own CIDRs. All remote workers of a federation export the same Service name, so one clusterset name covers them all. Record the cluster ID and the token expiry.

## Remove a remote node

1. Remove the worker and Submariner on the node, or reset the node.
2. On the central cluster, run `revoke-remote.sh CLUSTER_ID=<id>`.
3. Remove the node's entry from `remote-networks.yaml` and its `ipBlock`s from `submariner-policies/network-policy.yaml`.

## Check a join

1. Tunnel: `subctl show connections` shows `connected` on both sides; `subctl show gateways` on the node shows `active`.
2. Routing and DNS: the runbook's smoke test exports an nginx Service from the node and fetches it from the central cluster. The node's record must list the test Service during the test.
3. Federation: the worker is ready, `kubectl -n federation-z get serviceimport` lists `exareme2-test-workers-service`, and the controller's `/datasets_locations` lists the remote datasets.

`preflight.sh --stage health` checks the node's side.

## Versions and upgrades

| Component | Pin | Updated by |
| --- | --- | --- |
| Submariner chart, central | `common/submariner/operator/kustomization.yaml` | Renovate, group `submariner` |
| Submariner chart and `subctl`, remote | `SUBMARINER_VERSION` in `setup-tools.sh`, `join-submariner.sh`, `preflight.sh` | Renovate, same group |
| MicroK8s | `MICROK8S_CHANNEL` in `setup-microk8s.sh` | by hand, close to the central Kubernetes minor |
| exaflow worker image | `remote-node/exaflow-worker/statefulset.yaml` | Renovate; keep it equal to `exaflow_images.version` in `deployments/shared-apps/exareme2/values.yaml` |
| Remote tokens | expiry recorded at enrollment | by hand: enroll and join again before the expiry |

The pinned Submariner version is 0.25.0. Upgrade the central cluster and all nodes in one maintenance window:

1. Apply changes to the out-of-band RBAC.
2. Let Argo CD sync the central chart. The operator updates the CRDs and restarts its components; tunnels drop for about a minute.
3. Upgrade every remote node with the runbook (Operations, "Upgrade Submariner").
4. Run `check-central.sh` after the central sync and after the last node.

Across a libreswan major version (Submariner 0.21 to 0.24) the two ends refuse each other's child SAs, and the tunnels stay `connecting` until the node runs the same version. 0.24 and 0.25 both use libreswan 5. The MCS CRDs serve `v1beta1` and `v1alpha1` with the same schema, so 0.24 and 0.25 agents share the broker; the manifests use `v1beta1`.

A re-apply of the CoreDNS chart (RKE2 upgrade or restart) removes the `clusterset.local` forward from the cluster CoreDNS, and clusterset names stop resolving. `check-central.sh` detects it; `kubectl -n submariner-operator rollout restart deploy/submariner-operator` writes it again.

The out-of-band roles grant these verbs on purpose. Do not remove them:

- operator: `list` on `servicecidrs` (finds the service CIDR), `list` and `watch` on `brokers` (caches Broker objects in all namespaces);
- every component: ConfigMaps in `submariner-operator` (Role `submariner-component-config`);
- gateway: `list` and `watch` on Secrets in `submariner-operator` (its certificate requestor starts in every mode).

The chart also grants the operator write access to NetworkPolicies. The operator does not use it, so the out-of-band role leaves it out.

## Known gaps

- **Controller health check.** The controller resolves all `workers_dns` names together, also in its health check. One name that does not resolve, such as a remote node that is down, restarts the controller until it resolves. Add a clusterset name only after its remote workers are exported and ready, and remove it together with the last node.
- **No hub and spoke.** Submariner connects every gateway to every other one. Each remote node has a host firewall that allows IPsec only with the central gateway address (`setup-microk8s.sh`, and UFW in the hardening playbook), and the worker's NetworkPolicy admits only the central networks.
- **Policy routing on the gateway node.** The route agent installs the rule `from all lookup 150` and the table-150 routes once and does not repair them. A systemd-networkd restart can remove them, through its foreign-route cleanup or a DHCP address renewal. Every connection then shows `error` while the tunnels stay up. A networkd drop-in prevents the first cause. Watchdogs repair both: the DaemonSet `submariner-gateway-route-watchdog` on the central cluster and the service `submariner-route-watchdog` on remote nodes. Recovery takes about two minutes.
- **Leftover Lighthouse export records.** The Lighthouse agent treats every ServiceImport in its namespace that carries its cluster ID as an export record. A leftover record can publish an address the Service no longer has. `check-central.sh` reports such records. To fix: delete the leftover records, then the agent pod (`kubectl -n submariner-operator delete pod -l app=submariner-lighthouse-agent`). To export the service again, delete its ServiceExport and let Argo CD recreate it; do not apply the file by hand at the same time.
- **Enrollment records as policy parameters.** An account whose own record is missing, while other records exist, passes the subnet and export policies. The scripts keep the record in place while the account can write, and `check-central.sh` reports an account without one. Before Kubernetes 1.38 the API server stops reading the records for good once no bound policy uses them, without an error. Change the subnet and export policies with `kubectl apply` only, and always keep at least one of their bindings. `verify-enrollment.sh` shows the condition.
- **Unauthenticated exaflow interfaces.** The network decides who reaches them. The aggregation server accepts any caller from the federation's remote networks. A node that knows the request identifier of a computation can add to it, lower the number of expected workers, or remove it; a node learns the identifiers of the computations it takes part in. Without an identifier in the request the controller generates sequential ones, so requests must carry an identifier that cannot be guessed, such as a UUID.
- **Namespace labels.** The network-policy ApplicationSets manage the labels `name`, `mip.namespace-type` and `mip.federation-type` of each namespace. The notebook RBAC reconciler relies on `mip.namespace-type: federation`.

## Host hardening of remote nodes

The setup playbook of the linux-server-management repository hardens the hosts (inventory group `remote-nodes`, `inventories/mip/group_vars/remote-nodes/vars.yml`). The group provides what this design needs:

- outbound TCP 6443 to the broker API;
- UDP 500, 4500 and 4490 with the central gateway address only;
- traffic on `cali+`, `vxlan.calico` and `vx-submariner`, and forwarding between them and the uplink;
- host traffic into the tunnel towards the central pod and service CIDRs (gateway health check);
- IP forwarding and loose reverse-path filtering;
- the kernel modules `vxlan`, `esp4`, `xfrm_user`, `ip_set`, `nf_tables` and `squashfs`;
- the networkd drop-in and the route watchdog of the runbook;
- snap refreshes and automatic reboots in the same night window.

Inbound UDP 4500 and 4490 stay closed, because the node opens the tunnel. Open UDP 4800 between nodes and the metrics ports 8080 and 8081 only when a remote cluster gets a second node or is monitored.

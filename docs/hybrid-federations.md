# Hybrid federations

How a federation spans the central cluster and remote single-node clusters, and how the two sides are connected with Submariner.

## Shape

A **local** federation runs the whole MIP stack in one `federation-<name>` namespace on the central cluster (`deployments/local/`). A **hybrid** federation keeps the controller, the aggregation server and the user-facing MIP stack on the central cluster and runs the Exareme2 (exaflow) workers on remote nodes, typically one single-node MicroK8s cluster per site (`deployments/hybrid/`).

```
central cluster (RKE2)                          remote node (MicroK8s)
  federation-z namespace                          federation-z namespace
    exaflow-controller  ---- gRPC 5672 ---->        exaflow-localworker
    exaflow-aggregation <--- gRPC 50051 ---         (synthetic or site data)
    exaflow-globalworker <-- Flower 8080 --
    mip-stack
  submariner-operator: gateway (LoadBalancer)  <== IPsec / NAT-T ==  submariner-operator: gateway (node address)
  submariner-k8s-broker: broker (API server)   <-- TCP 6443 -------  operator, lighthouse agent
```

The remote node initiates the tunnel; the central gateway only needs to be reachable on UDP 4500 (and UDP 4490 for NAT discovery). Both clusters exchange routes for their pod and service CIDRs, so pods on either side reach the other side's pod and service addresses directly unless a policy denies it. Lighthouse publishes exported Services as `<service>.<namespace>.svc.clusterset.local` on every member.

## Central side

Everything on the central cluster is managed by Argo CD, except the out-of-band files under `base/mip-infrastructure/rbac/` and the per-node enrollment objects.

| Piece | Path | Notes |
| --- | --- | --- |
| Broker and operator Applications | `common/submariner/submariner.yaml`, `broker/`, `operator/` | Official charts, version pinned in both `kustomization.yaml` files (Renovate group `submariner`) |
| Out-of-band RBAC | `base/mip-infrastructure/rbac/submariner-rbac.yaml` | Cluster roles the AppProject may not create; applied once at bootstrap; also creates both Submariner namespaces |
| Per-remote accounts | `base/mip-infrastructure/rbac/submariner-remote-admission.yaml` | Role `submariner-remote-cluster` and two admission policies (ownership of broker objects, subnet pinning); applied once, out of band |
| Enrollment scripts | `deployments/hybrid/federations/federation-Z/enrollment/` | `enroll-remote.sh`, `verify-enrollment.sh`, `revoke-remote.sh`, run by the central operator per node |
| PostSync hook | `common/submariner/broker/copy-secret-hook.yaml` | Copies the broker client token and CA into `submariner-operator` and generates the IPsec PSK once, stored in `submariner-operator` only |
| Federation Applications | `deployments/hybrid/federations/federation-Z/mip-infrastructure/` | Discovered by both ApplicationSets (`deployments/hybrid/federations/*/mip-infrastructure`); deploys exareme2 and mip-stack into `federation-z` |
| Worker discovery | `.../customizations/exareme2-values.yaml` | `controller.workers_dns` lists the local headless worker Service and the clusterset name exported by the remote nodes |
| Remote allows | `.../submariner-policies/network-policy.yaml` | Port-scoped NetworkPolicies for the controller, the aggregation server and the global worker, one `ipBlock` per remote pod CIDR |
| ServiceExports | `.../submariner-policies/service-exports.yaml` | Aggregation server and controller, so remote workers can reach them by clusterset name |
| Cluster-wide deny | `common/security/remote-clusters/` | Calico Tier and GlobalNetworkPolicy denying remote CIDRs everywhere except the allowed components |

`federation-z.yaml` in the federation directory is a wrapper Application for manual bootstrap or testing; the ApplicationSet already discovers the directory, so it is not applied in normal operation.

Two prerequisites on the central cluster belong to the cluster installation (the provider's node and CNI configuration), not to this repository, and were both lost when the nodes were redeployed:

- One worker node must carry the label `submariner.io/gateway=true`; the gateway DaemonSet schedules only there, and MetalLB announces the gateway address from that node (`externalTrafficPolicy: Local`). The provider's node configuration sets the label; if it is missing after a redeploy, re-apply it by hand (`kubectl label node <worker> submariner.io/gateway=true`) and report it. Without it `subctl show gateways` reports no gateway and remote nodes cannot connect.
- The Calico API server (`APIService v3.projectcalico.org`) must be available: the operator's reconcile, the route agents' IP pools and the Calico tier and global policy all use `projectcalico.org/v3`. With the tigera operator the `APIServer` resource named `default` provides it. Symptoms of a broken one: `stale GroupVersion discovery: projectcalico.org/v3` in the Submariner operator log, `calico-apiserver` pods that never become ready, and `tigerastatus` degraded for `apiserver` and `ippools`. After a redeploy the observed cause was RBAC: the `calico-apiserver` account could not list ConfigMaps cluster-wide, so its informers never synced.

`deployments/hybrid/federations/federation-Z/enrollment/check-central.sh` runs these and the other central checks (broker registration, PSK placement, admission policies, namespace label, policy Applications) read-only; run it before every join.

## Remote side

The remote node is not managed by Argo CD. The runbook is [`deployments/hybrid/federations/federation-Z/remote-node/README.md`](../deployments/hybrid/federations/federation-Z/remote-node/README.md); it drives these scripts:

| Script | Purpose |
| --- | --- |
| `reset-node.sh` | Returns a node with an earlier attempt to a clean state |
| `preflight.sh` | Install-stage and join-stage checks with a PASS/WARN/FAIL table |
| `setup-tools.sh` | Base packages and `subctl` pinned to the Submariner version |
| `setup-microk8s.sh` | MicroK8s with the node's CIDRs, Calico API server, gateway label |
| `join-submariner.sh` | Helm install of the Submariner operator with the enrolled identity and credentials |
| `deploy-worker.sh` | exaflow worker, headless Service and ServiceExport from `exaflow-worker/` |

Parameters and their defaults are listed in the runbook. Real endpoints live only in the per-node values files `remote-node/submariner-values*.yaml` (`broker.server`); generated files with credentials and the cluster ID are ignored by git.

### Identities and cluster IDs

Each remote node is enrolled on the central cluster before it joins. Enrollment creates a ServiceAccount `cluster-<id>` in `submariner-k8s-broker`, bound to the Role `submariner-remote-cluster`, a ConfigMap recording the node's CIDRs, and a bound token with an expiry. The cluster ID (`rn-<8 hex>` by default) is chosen at enrollment, travels to the node in the credential files, and becomes the node's Submariner cluster ID and worker identity. The mapping from ID to site is kept in the internal tracking system, not in this repository.

Two admission policies constrain the `cluster-*` accounts: they may only create, update or delete broker objects that carry their own cluster ID (Cluster and Endpoint by `spec.cluster_id` and name, EndpointSlices and per-cluster ServiceImports by label, aggregated ServiceImports by their own entry in `status.clusters` and their own timestamp annotation), and the subnets they advertise must lie within the CIDRs recorded at enrollment. The chart's client account used by the central operator is not matched by the policies.

Revocation is `revoke-remote.sh`: deleting the account invalidates every token issued to it, and the node's broker objects are removed.

### Why Helm and not subctl

The broker is deployed by Helm through Argo CD, so no `broker-info.subm` file exists, and the IPsec PSK is held in a Kubernetes secret rather than in the `Submariner` resource. `subctl join` cannot consume that layout. The remote side therefore installs the `submariner-operator` chart directly with the enrolled identity and the three broker credentials as values. `subctl` is still installed, pinned to the same version, for `show`, `diagnose` and `uninstall`.

## Credentials and encodings

The remote node needs three values from the central cluster besides its cluster ID: its bound token, the broker CA and the IPsec PSK. Their encodings differ, and getting them wrong produces either `x509` errors (CA) or a tunnel that never authenticates (PSK):

| Value | Source on the central cluster | Passed to the chart as |
| --- | --- | --- |
| Token | `kubectl create token cluster-<id> --duration=<n>h` (enrollment) | plain |
| CA | `kube-root-ca.crt` ConfigMap (enrollment) | base64 |
| PSK | `secret/submariner-ipsec-psk` in `submariner-operator`, `.data.psk` | base64 as stored |

The PSK rule follows from the gateway implementation: when the PSK comes from a mounted secret (central side, `ceIPSecPSKSecret`), the gateway base64-encodes the secret bytes before configuring IPsec; when it comes from the `Submariner` resource (Helm value `ipsec.psk`), the string is used as is. The stored base64 string is therefore the value both sides end up using.

Two kinds of broker accounts exist in `submariner-k8s-broker`:

- The chart's client account, used only by the central operator. Its Role covers Submariner clusters and endpoints, ServiceImports, EndpointSlices, the Broker resource and secrets read; the last one is required because the operator references the credentials through `brokerK8sSecret` and runs a broker secret syncer that lists secrets in that namespace and waits for the list before reconciling. Consequently nothing sensitive besides that account's own token is stored there; the PSK lives in `submariner-operator`. This token is never handed out.
- One `cluster-<id>` account per remote node, bound to the narrower `submariner-remote-cluster` Role (no secrets, no service accounts, no Broker read) and constrained by the admission policies. Its token is passed to the remote inline through Helm values, so no secret syncer runs on the remote and no secrets access is needed. Rotation is a new enrollment run plus a re-run of the join; revocation is deleting the account.

A holder of a remote token together with the PSK can still register a cluster under that identity, within the enrolled subnets; the security review of 2026-09-17 lists the resulting exposure and the network containment that limits it.

## Verification

After a join, three layers are checked in order:

1. Tunnel: `subctl show connections` on both sides shows the peer as `connected` with the expected subnets; `subctl show gateways` on the node reports `active`.
2. Routing and DNS: the smoke test in the runbook exports an nginx Service from the node and resolves and fetches it from a pod on the central cluster (`remote-node/smoke-test.yaml`). With the containment in place the fetch must be run from a pod that the policies allow, or the test namespace must carry its own allow; the runbook says how.
3. Federation: the exaflow worker on the node becomes ready, `kubectl -n federation-z get serviceimport` on the central cluster lists `exareme2-test-workers-service`, and the controller's `/datasets_locations` endpoint lists the remote datasets under the worker identifier.

## Network policies

Hybrid namespaces receive the same default deny as local ones (`common/security/netpol.yaml` discovers `deployments/hybrid/federations/*/mip-infrastructure`). The flows the federation needs from its remote nodes are allowed per component and port in `submariner-policies/network-policy.yaml`:

| Flow | Direction on the central cluster | Port |
| --- | --- | --- |
| controller to remote worker (gRPC tasks) | egress from `app=exaflow-controller` to the remote pod CIDR | TCP 5672 |
| remote worker to aggregation server | ingress to `app=exaflow-aggregation-server` | TCP 50051 |
| remote Flower client to controller API | ingress to `app=exaflow-controller` | TCP 5000 |
| remote Flower client to Flower server | ingress to `app=exaflow-worker,nodeType=globalworker` | TCP 8080 |

Only pod CIDRs appear: the controller consumes a headless export (pod addresses), and remote pods keep their source address when they dial an exported ClusterIP because the Submariner route agent exempts that traffic from masquerading.

`common/security/remote-clusters/` adds a Calico Tier (order 500, before the default tier) with a GlobalNetworkPolicy that passes the four flows above to the namespaced policies, denies any other traffic from or to the remote CIDRs in every namespace, and passes everything else through. It protects namespaces without policies of their own (monitoring, `kube-system`, Argo CD, the Submariner namespaces). The policy matches hybrid federation namespaces by the label `mip.federation-type: hybrid`, which the `federation-network-policies` ApplicationSet sets on every federation namespace through `managedNamespaceMetadata` (`common/security/netpol.yaml`); a new hybrid federation is covered as soon as its directory is discovered, and a namespace without the label has its remote flows denied.

Residual: the Kubernetes API service address is host-terminated and outside the reach of workload policies; remote pods can reach it and are stopped only by authentication. The chart's worker isolation policies still select pre-1.0.0 labels and match no pod (tracked in `common/security/README.md`).

## Adding a remote node

Follow the runbook. Per node, the central side needs an enrollment (`enroll-remote.sh` with the node's CIDRs), one `ipBlock` for the node's pod CIDR in each rule of `submariner-policies/network-policy.yaml`, and the node's pod and service CIDRs in `common/security/remote-clusters/global-deny-remote-cidrs.yaml`; `scripts/check-remote-cidrs.sh` asserts the three places agree with the node's values file. The worker DNS name is shared by all remote nodes of the federation because every node exports a Service with the same name in `federation-z`, and Lighthouse merges them into one clusterset name. Choose non-overlapping CIDRs per node and record the node's cluster ID and token expiry.

Submariner connects every gateway to every other gateway. Two remote nodes therefore also try to reach each other; when one or both sit behind NAT those attempts never complete and remain in the gateway logs. They do not affect the connections to the central cluster.

## Removing a remote node

Remove the worker and Submariner on the node (or reset the node), then run `revoke-remote.sh` on the central cluster with the node's cluster ID: it deletes the account, its bindings and ConfigMap, and the node's `Cluster`, `Endpoint`, `EndpointSlice` and ServiceImport entries on the broker. Remove the node's CIDRs from the two policy files. Nothing else in Argo CD changes.

## Version alignment

| Component | Pin | Moved by |
| --- | --- | --- |
| Submariner charts, central | `common/submariner/{broker,operator}/kustomization.yaml` | Renovate, group `submariner` |
| `subctl` and chart, remote | `SUBMARINER_VERSION` in `setup-tools.sh` and `join-submariner.sh` | Renovate, same group |
| MicroK8s | `MICROK8S_CHANNEL` in `setup-microk8s.sh` | Manual, aligned with the central Kubernetes minor |
| exaflow worker image | `remote-node/exaflow-worker/statefulset.yaml` | Renovate `kubernetes` manager; must stay equal to `exaflow_images.version` in `deployments/shared-apps/exareme2/values.yaml` |
| Bound tokens | expiry recorded at enrollment | Manual: re-run `enroll-remote.sh` and the join before the expiry |

Upgrade order for Submariner: the out-of-band RBAC first when the release needs new permissions, then the central charts (Argo CD sync; the operator restarts, updates the CRDs and rolls its components, tunnels drop for about a minute), then every remote node with the updated runbook directory (`setup-tools.sh` for `subctl`, `join-submariner.sh` without credential files upgrades the release in place with the stored credentials). Plan the whole upgrade as one maintenance window: the 0.21 images ship libreswan 4 and the 0.24 images libreswan 5, and across that boundary the two ends establish the IKE SA but refuse each other's child-SA proposals (`CREATE_CHILD_SA failed with error notification NO_PROPOSAL_CHOSEN`), so every tunnel stays in `connecting` until the node side runs the same version. Traffic on already established tunnels survives the central restart for a while on the kernel's IPsec state, which makes the outage look partial. Run `enrollment/check-central.sh` after the central sync and after the last node: it verifies, among other things, that the `clusterset.local` forward is still present in the cluster CoreDNS Corefile. The operator writes that block once per reconcile and does not watch the ConfigMap, so a re-apply of the CoreDNS chart (RKE2 upgrade or restart) silently removes it and every clusterset name stops resolving on the central side until the operator is restarted.

Pinned version: 0.24.1. Minimum 0.21.1 for any cluster on Kubernetes 1.33 or later: older releases discover the service CIDR by parsing an API server error whose text changed in 1.33 and the operator then never creates the gateway; from 0.21.1 the operator reads the `ServiceCIDR` resource, which is why the out-of-band operator ClusterRole grants `servicecidrs get/list`. Since 0.24 the operator caches `Broker` objects cluster-wide, so the same ClusterRole grants `list` and `watch` on `submariner.io brokers` (no write verbs: no Broker object exists in a Helm-managed broker), and every component reads and watches ConfigMaps in the operator namespace at start-up, granted by the namespaced Role `submariner-component-config`. The gateway additionally lists and watches Secrets in that namespace (its certificate signing requestor starts in every authentication mode and the gateway stays passive until that informer syncs), granted by the Role `submariner-gateway-secrets`; the write verbs the upstream gateway Role carries for the certificate-auth mode are not granted. 0.22 switched the packet-filter driver to nftables (opt-out key `use-nftables` in the components' global ConfigMap); 0.24.1 hardened the broker trust model on the receiving side (gateways reject Endpoints whose subnets fall outside the CIDRs a cluster declared, Lighthouse rejects special-range addresses and imports into system namespaces), which complements the admission policies of this repository. The upstream broker validating webhook introduced in 0.24.1 needs cert-manager, is not part of the charts, and is not used here.

## Known gaps

- Worker discovery in the exaflow controller resolves all `workers_dns` names in a single pass, and the `/healthcheck` endpoint used by the startup and liveness probes repeats that resolution on every call. One unresolvable name (a remote node that is down or not yet exported) therefore fails the probe and restarts the controller until the name resolves again; the federation serves nothing in the meantime. Per-name error handling upstream would make remote nodes a soft dependency; until then a remote worker must be exported and ready before its clusterset name is added, and removing a remote node means removing its name from `workers_dns` in the same change.
- The worker's `CONTROLLER_IP` is only needed for Flower algorithms; the upstream chart derives it from service-link variables that do not exist across clusters, so the remote manifest sets the clusterset name explicitly.
- Submariner has no hub-and-spoke mode; remote-to-remote tunnel attempts are expected noise.
- The route agent installs the gateway node's host-network policy routing (rule `from all lookup 150`, table-150 routes to the remote CIDRs with the CNI address as source) only at gateway transition and endpoint events and never reconciles it. systemd-networkd deletes it at every start with its defaults, which an unattended openssl update triggered on every Ubuntu host on 2026-09-30: all connections showed `error` with the IPsec SAs up, and Lighthouse stopped answering for the affected clusters. Guarded by a networkd drop-in (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`): the DaemonSet `submariner-gateway-node-config` writes it on the central gateway node (no host access there, `common/submariner/README.md`), `setup-microk8s.sh` and the hardening post-run block on the remote nodes. Recovery is a restart of the route agent pod on the gateway node. Upstream note in `remote-nodes-work/upstream-contributions/submariner-routeagent-rule-reconcile/`.
- The exaflow gRPC and REST interfaces carry no authentication; an enrolled identity is trusted as a federation member. Application-layer authentication is an upstream topic.
- Namespace labels (`name`, `mip.namespace-type`, `mip.federation-type`) are managed by the network-policy ApplicationSets, whose Applications target the namespaces; the wrapper Applications of the `mip-infrastructure` ApplicationSet target the Argo CD namespace and carry no namespace metadata. Labels an earlier version put on `argocd-mip-team` are left in place and are harmless.

## OS hardening of the remote nodes

Host hardening is applied with the setup playbook of the linux-server-management repository; the inventory group `remote-nodes` (`inventories/mip/group_vars/remote-nodes/vars.yml`) carries the node-specific settings and the inventory README the procedure. The group satisfies the host requirements of this design: outbound TCP 6443 to the broker API and UDP 500/4500/4490 to the central gateway (destination-restricted), traffic on the `cali+`, `vxlan.calico` and `vx-submariner` interfaces and forwarding between them and the uplink, host-originated traffic into the tunnel to the central pod and service CIDRs (gateway health check), IP forwarding on, loose reverse-path filtering, the kernel modules `vxlan`, `esp4`, `xfrm_user`, `ip_set` and `nf_tables` loadable, `squashfs` loadable for the snaps, raised systemd file and process limits, a capped journal, the systemd-networkd drop-in that keeps foreign routes and rules (the route agent's policy routing on the gateway node), snap refreshes and automatic reboots in the same night window. Inbound UDP 4500/4490 is not opened: the node initiates the tunnel and replies are tracked. UDP 4800 between nodes and the metrics ports 8080/8081 are needed only when the remote cluster grows beyond one node or when monitoring scrapes the node; add them to the group then.

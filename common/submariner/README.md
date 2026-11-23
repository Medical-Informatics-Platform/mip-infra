# MIP Submariner Deployment

Deploys Submariner for multi-cluster connectivity in MIP infrastructure using official Submariner Helm charts.

## Overview

This deployment uses:
- Official `submariner-operator` Helm chart for cluster connectivity, rendered by Kustomize (`operator/`)
- Custom values files for environment-specific configuration
- Out-of-band namespaces and RBAC in `base/mip-infrastructure/rbac/submariner-rbac.yaml`

The central cluster hosts the broker and its own operator (this directory). The broker is the namespace `submariner-k8s-broker` with its out-of-band RBAC; the operator installs and updates the broker CRDs. The `submariner-k8s-broker` chart is not used: it would only add a client account with a long-lived token. Remote nodes join with the same operator chart, installed by Helm from `deployments/hybrid/federations/federation-Z/remote-node/`. Design notes: [docs/hybrid-federations.md](../../docs/hybrid-federations.md).

## Prerequisites

- Kubernetes (both clusters)
- Helm (on nodes where deploying manually)
- Calico CNI with VXLAN encapsulation and the Calico API server (`projectcalico.org/v3`), which the route agent uses to create IP pools
- Non-overlapping pod and service CIDRs across all clusters
- LoadBalancer service support (or MetalLB) for the broker cluster gateway
- Argo CD installed on the broker cluster
- Network: TCP 6443 from every remote cluster to the broker API server; UDP 4500 (IPsec NAT-T) and UDP 4490 (NAT discovery) to the central gateway address; UDP 4800 between nodes of the same cluster when a cluster has more than one node
- `subctl` matching the deployed Submariner version, for `show`, `diagnose` and `uninstall`

## Manual Installation guide for testing (we use argocd normally)

### 1. Deploy the operator (central cluster, through Argo CD)

```bash
# Apply the Argo CD Application
kubectl apply -f submariner.yaml

# Sync it
argocd app sync submariner-operator
```

The out-of-band RBAC in `base/mip-infrastructure/rbac/submariner-rbac.yaml` must exist beforehand (see `docs/getting-started.md`, step 3), and so must the IPsec PSK (next section).

The operator reaches the broker with its own account `submariner-operator/submariner-broker-client` (`operator/broker-credentials.yaml`). Kubernetes writes the token and the cluster CA into its Secret `submariner-broker-client-token` (type `kubernetes.io/service-account-token`), which `submariner.brokerK8sSecret` references. The account's broker Role can read Secrets in the broker namespace, as the operator's broker secret syncer requires, so keep no Secret there; `check-central.sh` checks this. Remote clusters do not get this token. Each has its own `cluster-<id>` account with a narrower Role and bound tokens (`docs/hybrid-federations.md`).

### 2. IPsec PSK

All clusters of the clusterset share the PSK. It is not stored in git. Create it once, before the first sync, in `submariner-operator` only:

```bash
kubectl -n submariner-operator create secret generic submariner-ipsec-psk --from-literal=psk="$(openssl rand -base64 64 | tr -d '\n')"
```

`ipsec.pskSecret` references it. Replacing it re-keys the clusterset: every remote cluster must then be enrolled and joined again. Remote clusters get it at enrollment (`deployments/hybrid/federations/federation-Z/enrollment/enroll-remote.sh`), with their own bound token and the broker CA.

### 3. Deploy to Remote Cluster

See [deployments/hybrid/federations/federation-Z/remote-node/README.md](../../deployments/hybrid/federations/federation-Z/remote-node/README.md).

## Delete behavior

The child Argo CD Applications in [common/submariner/submariner.yaml](submariner.yaml)
intentionally do not use `resources-finalizer.argocd.argoproj.io`.

Why:
- The `submariner-operator` Application manages both the operator Deployment and a live `Submariner` custom resource.
- A cascading Application delete tears down the controller and the controller-owned custom resource in the same operation.
- In practice, that can deadlock deletion: the `Submariner` resource is left waiting on its own cleanup finalizers after the operator is already being removed.

Consequence:
- Deleting the child Application removes the Argo CD Application object only.
- The deployed Submariner resources stay in the cluster.
- The parent App-of-Apps can recreate the child Application cleanly.

For a real uninstall, do it in controller order:
- delete the `Submariner` custom resource first and wait for its cleanup to complete
- then remove the operator workload
- then remove the broker namespace if needed

## Configuration

### Key Values

Operator values are in `operator/values.yaml`:

- `submariner.clusterId`: unique identifier of this cluster in the clusterset
- `submariner.clusterCidr`: pod network CIDR
- `submariner.serviceCidr`: service network CIDR (empty lets the operator discover it)
- `submariner.natEnabled`, `submariner.loadBalancerEnabled`, `submariner.cableDriver`
- The gateway LoadBalancer address and MetalLB pool: `spec.loadBalancerServiceAnnotations`, patched onto the `Submariner` resource in `operator/kustomization.yaml` (the chart has no value for it). See "Gateway node".
- `submariner.brokerK8sSecret` and `ipsec.pskSecret`: the Secrets with the broker credentials and the PSK. The operator mounts them as files, not as environment variables. `broker.token`, `broker.ca` and `ipsec.psk` stay empty.

Globalnet is not used (the CIDRs of all clusters are distinct).

See the official chart documentation for all available options:
- [submariner-operator chart](https://github.com/submariner-io/submariner-charts/tree/main/submariner-operator)

## Gateway node

The operator owns the LoadBalancer Service `submariner-gateway`. It creates it with UDP 4500 (IPsec NAT-T) and UDP 4490 (NAT discovery) and replaces its spec on every reconcile. The address is therefore pinned with the MetalLB annotation `metallb.io/loadBalancerIPs` in `spec.loadBalancerServiceAnnotations` of the `Submariner` resource; the operator merges these annotations into the Service. Remote nodes exchange IPsec only with this address. It is set in three places that must change together: `operator/kustomization.yaml`, `deployments/hybrid/federations/federation-Z/remote-node/central.env` and the remote-nodes group of the hardening inventory. `check-central.sh` checks the assigned address and both ports.

The gateway DaemonSet schedules only on a node labelled `submariner.io/gateway=true`, and MetalLB announces the gateway address from that node. The label is part of the cluster provider's node configuration, not of this repository; after a node redeploy, confirm it with `subctl show gateways` or `deployments/hybrid/federations/federation-Z/enrollment/check-central.sh`, re-apply it by hand if missing (`kubectl label node <worker> submariner.io/gateway=true`) and report it to the provider.

`operator/gateway-node-networkd.yaml` adds the DaemonSet `submariner-gateway-node-config`, scheduled on the same label. It writes `/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf` (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`) on the gateway node and idles. systemd-networkd deletes routes and routing policy rules it does not own at every start, which removes the policy routing the route agent installs on the gateway node (rule `from all lookup 150`, table-150 routes to the remote CIDRs with the CNI address as source); the gateway's health-check pings then leave with the node address, every connection turns to `error` although the IPsec SAs stay up, and Lighthouse stops answering for the remote clusters. Seen on 2026-09-30 when an unattended openssl update restarted networkd through needrestart on every Ubuntu host. The pod mounts only that directory, has no network, API access or capabilities, and restarts nothing; the file takes effect at the next networkd start. It exists because the cluster nodes are not reachable over SSH. Recovery after such an event is a restart of the route agent pod on the gateway node, which re-installs the rule and routes within seconds:

```bash
kubectl -n submariner-operator delete pod -l app=submariner-routeagent --field-selector spec.nodeName=$(kubectl get nodes -l submariner.io/gateway=true -o jsonpath='{.items[0].metadata.name}')
kubectl -n submariner-operator exec ds/submariner-gateway -- sh -c 'ip rule show | grep 150; ip route show table 150'
```

The operator Application syncs with `prune: false`; removing the manifest from git leaves the DaemonSet and the file in place.

`operator/gateway-route-watchdog.yaml` adds the DaemonSet `submariner-gateway-route-watchdog`, scheduled on the same label. The route agent does not re-add a route it has already installed, and the networkd drop-in prevents only one cause of loss. On the node of the active gateway, the watchdog compares table 150 with the subnets of all remote Endpoints every minute. After two failed checks in a row, it deletes the route agent pod on that node, at most once per 15 minutes. Each failed check is logged with the table content (`kubectl -n submariner-operator logs ds/submariner-gateway-route-watchdog`). `check-central.sh` reports the restarts of the last 7 days.

The pod uses the host network to read the routing tables. It opens no port, has no capabilities, runs as non-root with a read-only root filesystem and uses a one-hour projected token. Apply its Role in `base/mip-infrastructure/rbac/submariner-rbac.yaml` before the sync, like the other out-of-band RBAC. The image `alpine/kubectl` is pinned by digest and must stay within kubectl's version skew of the API server. Update the tag and digest together.

## Verification

`deployments/hybrid/federations/federation-Z/enrollment/check-central.sh` runs the checks below and the ones remote nodes depend on, read-only.

```bash
# Check broker pods
kubectl get pods -n submariner-k8s-broker

# Check operator pods
kubectl get pods -n submariner-operator

# Check connections (after a remote cluster joins)
subctl show connections
subctl show gateways

# Members registered on the broker
kubectl -n submariner-k8s-broker get clusters.submariner.io,endpoints.submariner.io
```

End-to-end routing and clusterset DNS are checked with the smoke test described in the remote-node README (an exported nginx Service resolved and fetched from a pod on this cluster).

## Customization with Kustomize

For settings not exposed by Helm charts, use Kustomize patches in `kustomization.yaml`.

Example: the gateway LoadBalancer address and MetalLB pool, patched onto the `Submariner` resource in `operator/kustomization.yaml`.

## Troubleshooting

See the troubleshooting section of the remote-node README for tunnel, DNS and credential problems, and `docs/troubleshooting.md` for Argo CD-level issues such as Applications stuck on finalizers.

# MIP Submariner Deployment

Deploys Submariner for multi-cluster connectivity in MIP infrastructure using official Submariner Helm charts.

## Overview

This deployment uses:
- Official `submariner-k8s-broker` Helm chart for broker components
- Official `submariner-operator` Helm chart for cluster connectivity
- Custom values files for environment-specific configuration
- Kustomize for additional customization when needed

The central cluster hosts the broker and its own operator (this directory). Remote nodes join with the same operator chart, installed by Helm from `deployments/hybrid/federations/federation-Z/remote-node/`. Design notes: [docs/hybrid-federations.md](../../docs/hybrid-federations.md).

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

### 1. Deploy Broker and Operator (Public Cluster via Argo CD)

```bash
# Apply the Argo CD Applications
kubectl apply -f submariner.yaml

# Sync the applications
argocd app sync submariner-broker
argocd app sync submariner-operator
```

The out-of-band RBAC in `base/mip-infrastructure/rbac/submariner-rbac.yaml` must exist beforehand (see `docs/getting-started.md`, step 3). The PostSync hook `broker/copy-secret-hook.yaml` then copies the broker client token and CA into `submariner-operator` and generates the IPsec PSK (`submariner-ipsec-psk`) once, in `submariner-operator` only. The client Role can read secrets in the broker namespace (the operator's broker secret syncer requires it), so nothing sensitive besides that account's own token may be stored there; the PSK is kept in `submariner-operator`. Remote clusters do not receive this token; each gets its own `cluster-<id>` account with a narrower Role (see `docs/hybrid-federations.md`).

### 2. Get Broker Info

The broker chart creates the service account `submariner-broker-submariner-k8s-broker-client` and its token secret. Remote clusters use that token, the broker CA and the shared PSK:

```bash
umask 077
S=submariner-broker-submariner-k8s-broker-client-token
kubectl -n submariner-k8s-broker get secret "$S" -o jsonpath='{.data.token}' | base64 -d > broker-token.txt   # decoded
kubectl -n submariner-k8s-broker get secret "$S" -o jsonpath='{.data.ca\.crt}' > broker-ca-base64.txt         # base64 as stored
kubectl -n submariner-operator get secret submariner-ipsec-psk -o jsonpath='{.data.psk}' > broker-psk.txt     # base64 as stored
```

The CA and the PSK are passed to the operator chart encoded, the token decoded; the reasons are explained in `docs/hybrid-federations.md` ("Credentials and encodings"). Credentials are never written into tracked files.

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
- then remove the broker workload if needed

## Configuration

### Key Values

Operator values are in `operator/values.yaml`, broker values in `broker/values.yaml`:

- `submariner.clusterId`: unique identifier of this cluster in the clusterset
- `submariner.clusterCidr`: pod network CIDR
- `submariner.serviceCidr`: service network CIDR (empty lets the operator discover it)
- `submariner.natEnabled`, `submariner.loadBalancerEnabled`, `submariner.cableDriver`
- `service.loadBalancerIP` and the MetalLB annotations for the gateway service (also patched in `patches/gateway-loadbalancer-ip.yaml`)
- `globalnet.enabled` (broker): enable for overlapping CIDRs (false by default)

The broker token and CA are not set in values; `operator/kustomization.yaml` patches the `Submariner` resource with `brokerK8sSecret: submariner-broker-secret` and `ceIPSecPSKSecret: submariner-ipsec-psk`, both created by the PostSync hook.

See official chart documentation for all available options:
- [submariner-k8s-broker chart](https://github.com/submariner-io/submariner-charts/tree/main/submariner-k8s-broker)
- [submariner-operator chart](https://github.com/submariner-io/submariner-charts/tree/main/submariner-operator)

## Gateway node

The gateway DaemonSet schedules only on a node labelled `submariner.io/gateway=true`, and MetalLB announces the gateway address from that node. The label is part of the cluster provider's node configuration, not of this repository; after a node redeploy, confirm it with `subctl show gateways` or `deployments/hybrid/federations/federation-Z/enrollment/check-central.sh`, re-apply it by hand if missing (`kubectl label node <worker> submariner.io/gateway=true`) and report it to the provider.

`operator/gateway-node-networkd.yaml` adds the DaemonSet `submariner-gateway-node-config`, scheduled on the same label. It writes `/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf` (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`) on the gateway node and idles. systemd-networkd deletes routes and routing policy rules it does not own at every start, which removes the policy routing the route agent installs on the gateway node (rule `from all lookup 150`, table-150 routes to the remote CIDRs with the CNI address as source); the gateway's health-check pings then leave with the node address, every connection turns to `error` although the IPsec SAs stay up, and Lighthouse stops answering for the remote clusters. Seen on 2026-09-30 when an unattended openssl update restarted networkd through needrestart on every Ubuntu host. The pod mounts only that directory, has no network, API access or capabilities, and restarts nothing; the file takes effect at the next networkd start. It exists because the cluster nodes are not reachable over SSH. Recovery after such an event is a restart of the route agent pod on the gateway node, which re-installs the rule and routes within seconds:

```bash
kubectl -n submariner-operator delete pod -l app=submariner-routeagent --field-selector spec.nodeName=$(kubectl get nodes -l submariner.io/gateway=true -o jsonpath='{.items[0].metadata.name}')
kubectl -n submariner-operator exec ds/submariner-gateway -- sh -c 'ip rule show | grep 150; ip route show table 150'
```

The operator Application syncs with `prune: false`; removing the manifest from git leaves the DaemonSet and the file in place.

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

Example: Setting a specific LoadBalancer IP (see `patches/` directory).

## Troubleshooting

See the troubleshooting section of the remote-node README for tunnel, DNS and credential problems, and `docs/troubleshooting.md` for Argo CD-level issues such as Applications stuck on finalizers.

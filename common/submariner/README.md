# Submariner (central cluster)

This directory deploys the Submariner operator on the central cluster. Submariner connects the central cluster to the remote nodes of hybrid federations. The central cluster also hosts the broker: the namespace `submariner-k8s-broker`, where the clusters publish their endpoints and exports.

- Design: [docs/hybrid-federations.md](../../docs/hybrid-federations.md)
- Remote nodes: [remote-node runbook](../../deployments/hybrid/federations/federation-Z/remote-node/README.md)

| Path | Content |
| --- | --- |
| `submariner.yaml` | Argo CD Application `submariner-operator` |
| `operator/` | The operator chart (rendered by Kustomize with `values.yaml`), the operator's broker account, the gateway-node DaemonSets |
| `base/mip-infrastructure/rbac/submariner-rbac.yaml` | Namespaces and RBAC, applied by hand: the Argo CD project may not create them |

There is no broker chart. The operator installs the broker CRDs itself.

## Prerequisites

- Calico with VXLAN and the Calico API server (`projectcalico.org/v3`). The route agent creates IP pools through it.
- Pod and service CIDRs that no other cluster of the clusterset uses.
- MetalLB, or another LoadBalancer, for the gateway address.
- Network: TCP 6443 from every remote node to the API server, and UDP 4500 and 4490 to the gateway address. UDP 4800 between the nodes of a cluster that has several nodes.
- `subctl` at the deployed version, for `show`, `diagnose` and `uninstall`.

## Install

1. Apply the out-of-band RBAC: `kubectl apply -f base/mip-infrastructure/rbac/submariner-rbac.yaml` (see [getting started](../../docs/getting-started.md), step 3).
2. Create the IPsec PSK once, in `submariner-operator` only. All clusters of the clusterset share it, and it is never stored in git:

   ```bash
   kubectl -n submariner-operator create secret generic submariner-ipsec-psk \
     --from-literal=psk="$(openssl rand -base64 64 | tr -d '\n')"
   ```

   Replacing the PSK re-keys the clusterset: every remote node must then be enrolled and joined again.
3. Let Argo CD sync the Application `submariner-operator` (by hand: `argocd app sync submariner-operator`).

The operator reaches the broker with its own account, `submariner-operator/submariner-broker-client` (`operator/broker-credentials.yaml`). Kubernetes writes the account's token and the cluster CA into the Secret `submariner-broker-client-token`, and `submariner.brokerK8sSecret` points to it. The token does not expire. To rotate it, delete the Secret: Argo CD recreates it and Kubernetes issues a new token.

The account's Role may read Secrets in the broker namespace, so keep no Secret there. Remote nodes never get this token; each has its own `cluster-<id>` account.

## Configuration

`operator/values.yaml`:

- `submariner.clusterId`: this cluster's ID in the clusterset.
- `submariner.clusterCidr`: the pod CIDR. `submariner.serviceCidr` stays empty; the operator finds it.
- `submariner.brokerK8sSecret` and `ipsec.pskSecret`: the Secrets with the broker credentials and the PSK. The operator mounts them as files. Leave `broker.token`, `broker.ca` and `ipsec.psk` empty.
- Globalnet is off: the CIDRs of all clusters differ.

Settings the chart does not offer are Kustomize patches in `operator/kustomization.yaml`, such as the gateway address below.

## Gateway node

The gateway runs on the node labelled `submariner.io/gateway=true`, and MetalLB announces the gateway address from it. The label belongs to the provider's node configuration. After a node redeploy, check it with `subctl show gateways` or `check-central.sh`. If it is missing, run `kubectl label node <worker> submariner.io/gateway=true` and tell the provider.

The operator owns the LoadBalancer Service `submariner-gateway` (UDP 4500 and 4490) and replaces its spec on every reconcile. The address is therefore pinned with the annotation `metallb.io/loadBalancerIPs` in `spec.loadBalancerServiceAnnotations` of the `Submariner` resource. Remote nodes exchange IPsec only with this address. It is set in three places; change them together:

- `operator/kustomization.yaml`
- `deployments/hybrid/federations/federation-Z/remote-node/central.env`
- the `remote-nodes` group of the hardening inventory

On the gateway node, the route agent installs the rule `from all lookup 150` and the table-150 routes to the remote CIDRs once. If they disappear, the gateway's health-check pings fail: every connection shows `error` while the tunnels stay up, and Lighthouse stops answering for the remote clusters. The central nodes are not reachable over SSH, so two DaemonSets on the gateway node deal with it:

- `submariner-gateway-node-config` (`operator/gateway-node-networkd.yaml`) writes the networkd drop-in `/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf` (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`), so that a networkd restart keeps the routes. The pod mounts only that directory, has no network, API access or capabilities, and restarts nothing. The file applies at the next networkd start.
- `submariner-gateway-route-watchdog` (`operator/gateway-route-watchdog.yaml`) repairs the other losses. Every minute it reads the Gateway object of its node. When the gateway is active and a connection is in `error` in two checks in a row, it deletes the route agent pod on that node, and the new pod re-installs the rule and the routes. Restarts are at least 15 minutes apart. While a restart does not clear the errors, the interval doubles, up to 4 hours. Log: `kubectl -n submariner-operator logs ds/submariner-gateway-route-watchdog`.

The watchdog does not use the host network, so Calico policy and the remote-clusters tier apply to it. It opens no port, runs as non-root without capabilities on a read-only root filesystem, and uses a one-hour token. Its Role allows `get` on Gateway objects and `deletecollection` on pods. The admission policy `submariner-gateway-route-watchdog` limits the deletes to the route agent pod on its own node. Both are in `submariner-rbac.yaml`; apply them before the sync. The image `alpine/kubectl` is pinned by digest and must stay within kubectl's version skew of the API server; change the tag and the digest together.

To repair by hand, restart the route agent on the gateway node and look at the table:

```bash
kubectl -n submariner-operator delete pod -l app=submariner-routeagent \
  --field-selector spec.nodeName=$(kubectl get nodes -l submariner.io/gateway=true -o jsonpath='{.items[0].metadata.name}')
kubectl -n submariner-operator exec ds/submariner-gateway -- sh -c 'ip rule show | grep 150; ip route show table 150'
```

## Check

`deployments/hybrid/federations/federation-Z/enrollment/check-central.sh` checks the central side and everything the remote nodes depend on. Quick looks:

```bash
kubectl -n submariner-operator get pods
subctl show connections
subctl show gateways
kubectl -n submariner-k8s-broker get clusters.submariner.io,endpoints.submariner.io   # registered clusters
```

The smoke test of the remote-node runbook checks routing and clusterset DNS end to end.

## Delete

The Application in `submariner.yaml` has no `resources-finalizer.argocd.argoproj.io`. A cascading delete would remove the operator together with the `Submariner` resource, whose cleanup needs the operator, and the deletion would hang. Deleting the Application removes only the Application object; the parent Application can recreate it.

To uninstall Submariner:

1. Delete the `Submariner` resource and wait until its cleanup ends.
2. Remove the operator.
3. Remove the broker namespace, if needed.

The Application syncs with `prune: false`. A manifest removed from git stays on the cluster until you delete it.

## Troubleshooting

- Tunnel, DNS and credential problems: the troubleshooting section of the remote-node runbook.
- Argo CD problems, such as Applications stuck on finalizers: [docs/troubleshooting.md](../../docs/troubleshooting.md).

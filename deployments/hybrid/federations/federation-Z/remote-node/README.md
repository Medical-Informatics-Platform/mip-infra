# Remote node runbook (federation-Z)

This runbook turns a fresh Ubuntu 24.04 VM into a remote node of the hybrid federation `federation-z`. It installs MicroK8s with the node's own CIDRs and joins the central Submariner broker under an identity enrolled on the central cluster. It then deploys an exaflow worker that the central controller finds through clusterset DNS.

Argo CD manages nothing on the node; the scripts in this directory do everything. Design: [docs/hybrid-federations.md](../../../../../docs/hybrid-federations.md).

## Overview

| Side | Component | Defined in |
| --- | --- | --- |
| Central (RKE2) | Submariner operator and broker, gateway on a LoadBalancer address | `common/submariner/` |
| Central | Broker accounts of the remote nodes, admission policies, enrollment scripts | `base/mip-infrastructure/rbac/submariner-remote-admission.yaml`, `../enrollment/` |
| Central | exaflow controller and aggregation server, network policies, ServiceExport | `../mip-infrastructure/` |
| Central | Calico tier that confines the remote networks | `common/security/`, `../mip-infrastructure/remote-networks.yaml` |
| Remote (this node) | Single-node MicroK8s with RBAC, Calico with VXLAN, Calico API server, Submariner operator | `setup-microk8s.sh`, `join-submariner.sh`, `submariner-values.yaml` |
| Remote | exaflow local worker, headless Service `exareme2-test-workers-service`, ServiceExport | `exaflow-worker/`, `deploy-worker.sh` |

The node opens the IPsec tunnel to the central gateway; the node has no LoadBalancer (`natEnabled: true`). Two flows cross the tunnel:

- The central controller resolves `exareme2-test-workers-service.federation-z.svc.clusterset.local` to the worker pod and dials it on TCP 5672.
- The worker sends results to `exaflow-aggregation-service.federation-z.svc.clusterset.local:50051`.

The central cluster denies every other flow, including the controller's HTTP API and the Flower server. Flower algorithms therefore do not run on remote workers.

## Parameters

| Parameter | Default | Used by | Notes |
| --- | --- | --- | --- |
| `SUBMARINER_VERSION` | `0.25.0` | `setup-tools.sh`, `join-submariner.sh`, `preflight.sh` | Equal to the chart version in `common/submariner/operator/kustomization.yaml`. `subctl` is pinned to it and checked against the release's SHA-256 list. |
| `MICROK8S_CHANNEL` | `1.33/stable` | `setup-microk8s.sh` | A Kubernetes minor close to the central cluster's. The two do not have to match. |
| `IPv4_CLUSTER_CIDR` | `10.3.0.0/16` | `setup-microk8s.sh`, the node's values file, enrollment `SUBNETS` | Pod CIDR. Must be private (RFC 1918: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and must not overlap the central pod CIDR (`10.42.0.0/16`), the central service CIDR or another remote node. |
| `IPv4_SERVICE_CIDR` | `10.152.185.0/24` | same | Service CIDR. Same rule. |
| `VALUES_FILE` | `submariner-values.yaml` | `join-submariner.sh` | One file per node, because the CIDRs are literals (`submariner-values-node2.yaml` for the second node). The join refuses a file whose CIDRs differ from the live cluster. |
| `DATASET` | `synthetic_a` | `deploy-worker.sh` | The CSV of `exaflow-worker/data/synthetic_v_0_1/` this node serves. Every node serves a different one. |
| `CENTRAL_GATEWAY_IP` | from `central.env` | `setup-microk8s.sh`, `preflight.sh` | The central gateway's LoadBalancer address, the only IPsec peer the node accepts. Equal to the address pinned in `common/submariner/operator/kustomization.yaml` and in the hardening inventory. |
| Cluster ID | `rn-<8 hex>`, chosen at enrollment | `enroll-remote.sh`, `join-submariner.sh`, `deploy-worker.sh` | Name suffix of the broker account `cluster-<id>`; delivered in `cluster-id.txt`. Record it with the site and the token expiry in the internal tracking system. |
| `TOKEN_DURATION` | `8760h` | `enroll-remote.sh` | Lifetime of the node's token. Enroll and join again before it ends. |
| `EXPORTS` | `federation-z/exareme2-test-workers-service` | `enroll-remote.sh` | The services the node may publish, as comma-separated `<namespace>/<service>`. The default comes from `exaflow-worker/serviceexport.yaml`. The broker refuses every other export of the node. |
| `broker.server` | in `submariner-values.yaml` | `join-submariner.sh`, `preflight.sh` | The central API server `<broker-api-host>:6443`, the only real endpoint in this directory. |

Changing the CIDRs after the installation needs `snap remove --purge microk8s` and a new enrollment. Changing the cluster ID needs the removal procedure below.

## Prerequisites

- Ubuntu 24.04 LTS amd64, sudo, 2 vCPU, 4 GB RAM, 40 GB disk, synchronised time.
- A host name that no node of the central cluster uses, and that stays the same across reboots. `setup-microk8s.sh` stops cloud-init from changing it (`preserve_hostname: true`). A node that boots under another name registers twice (see Troubleshooting).
- Outbound from the node: TCP 6443 to `<broker-api-host>`; UDP 4500 and 4490 to the central gateway address; TCP 443 to `api.snapcraft.io`, `quay.io`, `registry-1.docker.io`, `github.com`, `raw.githubusercontent.com`, `submariner-io.github.io` and `api.ipify.org`. Inbound UDP is not needed: the node opens the tunnel.
- On the central cluster:
  - `kubectl` with cluster-admin rights, for steps 1 and 7;
  - `base/mip-infrastructure/rbac/submariner-rbac.yaml` and `submariner-remote-admission.yaml` applied;
  - the node's CIDRs merged and synced (see Add another remote node);
  - `subctl` at the pinned version;
  - `../enrollment/check-central.sh` passes. After a node redeploy, the gateway label and the Calico API server are the usual failures; both belong to the cluster installation.
- A VM snapshot before each step that changes the node (steps 0, 4, 5 and 8).

Copy this directory to the node:

```bash
scp -r deployments/hybrid/federations/federation-Z/remote-node <user>@<remote-node>:remote-node
```

## 0) Reset a reused node

Only for a node that carries an earlier attempt; `preflight.sh` reports an installed MicroK8s snap.

```bash
sudo ./reset-node.sh --reboot
```

The script removes MicroK8s and its data, old helm and kubectl snaps, `subctl`, the user's MicroK8s kubeconfig and Helm caches, the persisted cluster ID, leftover credential files, the route watchdog and its credential, and the Submariner and Calico network state. Then revoke the node's previous identity on the central cluster: `../enrollment/revoke-remote.sh CLUSTER_ID=<previous id>`.

## 1) Enroll the node (central cluster)

Enrollment creates the broker account `cluster-<id>` and its RoleBinding, and the enrollment record: the node's CIDRs and the services it may publish. It issues a bound token and collects the broker CA and the IPsec PSK. Run it with cluster-admin `kubectl` for the central cluster:

```bash
cd deployments/hybrid/federations/federation-Z/enrollment
./enroll-remote.sh SUBNETS=10.3.0.0/16,10.152.185.0/24 OUT_DIR=~/subm-creds BROKER_URL=https://<broker-api-host>:6443
./verify-enrollment.sh OUT_DIR=~/subm-creds
```

- `enroll-remote.sh` prints the cluster ID and the token expiry. Record both with the site.
- Pass `CLUSTER_ID=<id>` to enroll an existing node again (new token). Pass the same `SUBNETS` and `EXPORTS` as before: a run rewrites the record, and the script warns when the record changes. Without `CLUSTER_ID` every run creates a new account; revoke unused ones with `revoke-remote.sh`.
- `verify-enrollment.sh` uses only the issued token, with server-side dry runs. The node's own objects must be admitted. Objects with another cluster's ID, other subnets or other services must be refused, and Secrets must be unreadable.
- Through the SSH SOCKS tunnel of `docs/remote-access.md`, the script finds `socks5://127.0.0.1:1080` itself; `PROXY_URL` overrides it.

The output directory holds:

| File | Content | Passed to the chart as |
| --- | --- | --- |
| `cluster-id.txt` | the cluster ID | `submariner.clusterId` |
| `broker-token.txt` | the token of `cluster-<id>`, plain text | `broker.token` |
| `broker-ca-base64.txt` | the broker CA, base64 | `broker.ca` |
| `broker-psk.txt` | `.data.psk` of `submariner-ipsec-psk`, base64 as stored | `ipsec.psk` (use it as is: both sides use the stored string) |
| `broker-ca.crt`, `broker-url.txt`, `subnets.txt`, `exports.txt`, `token-expiry.txt` | PEM CA, API URL, the record, the expiry | read by `verify-enrollment.sh` |

These files let their holder act as this node on the broker. Keep them under `umask 077`, transfer them only over SSH, and shred them after the join (step 7). If they leak, `revoke-remote.sh` invalidates them.

```bash
ssh <user>@<remote-node> 'umask 077 && mkdir -p subm-creds'
scp -p ~/subm-creds/cluster-id.txt ~/subm-creds/broker-token.txt ~/subm-creds/broker-ca-base64.txt ~/subm-creds/broker-psk.txt <user>@<remote-node>:subm-creds/
```

## 2) Check the node

```bash
cd ~/remote-node
./preflight.sh
```

The install stage checks:

- the OS, memory, disk, snapd and time synchronisation;
- the broker API: name resolution and TCP; the route to the central gateway address; HTTPS to the download sources;
- the kernel modules `esp4`, `xfrm_user`, `vxlan` and `ip_set`;
- that UDP 500, 4500, 4490 and 4800 are free;
- that the node's CIDRs overlap neither the central CIDRs nor the node addresses.

UDP to the gateway cannot be tested without a peer; `subctl show connections` confirms it after the join. Fix every `FAIL`; `WARN` lines are information.

## 3) Install the tools

```bash
sudo ./setup-tools.sh
```

It installs the base packages (`curl`, `jq`, `nftables`, `openssl`, `python3` and others, and `snapd` when missing) and `subctl` at `SUBMARINER_VERSION`. A newer `subctl` than the deployed version causes errors. MicroK8s provides `kubectl` and `helm` in the next step.

## 4) Install MicroK8s

```bash
sudo MICROK8S_CHANNEL=1.33/stable IPv4_CLUSTER_CIDR=10.3.0.0/16 IPv4_SERVICE_CIDR=10.152.185.0/24 ./setup-microk8s.sh
```

The script:

- Writes the MicroK8s launch configuration (`/var/snap/microk8s/common/.microk8s.yaml`) with the CIDRs, the `dns` addon and the authorization modes below, installs MicroK8s and waits for Calico and CoreDNS. On an installed node it checks the channel and the live CIDRs instead.
- Turns on RBAC in the API server (`RBAC,Node`). MicroK8s starts with `AlwaysAllow`: any pod's token, the worker's included, then controls the cluster and reads the broker token and the PSK stored in it. On an existing node the script runs `microk8s enable rbac`, which restarts the control plane once: the API is gone for about a minute, while the pods, the tunnel and cluster DNS keep running. It then checks that an identity without a role is refused. The MicroK8s admin kubeconfig (used by `kubectl`, `helm` and `subctl`) is in `system:masters` and keeps its access.
- Sets the kubelet's authorization to `Webhook`. Otherwise a pod that reaches port 10250 could run commands in every container of the node, even with RBAC on the API server. The script checks that the kubelet answers 403 to a token without a role and that `kubectl logs` still works.
- Creates the `kubectl` and `helm` aliases, adds you to the `microk8s` group and writes your kubeconfig.
- Installs the Calico API server, which the route agent needs to create IP pools. Its certificate lasts 365 days. The script also grants the kube-controller-manager read access to Calico tiers (`calico-tier-getter`); without it the garbage collector never syncs.
- Pins Calico's address detection to `kubernetes-internal-ip` and stops MicroK8s from re-issuing its certificates when a host address changes. Both would otherwise react to the `vx-submariner` interface that appears at the join.
- Writes the systemd-networkd drop-in `/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf` (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`), so that a networkd restart keeps the gateway's policy routing.
- Installs the route watchdog, the service `submariner-route-watchdog`. Every minute it compares table 150 with the subnets of the remote endpoints in the Gateway status. After two failed checks in a row it restarts the route agent, at most every 15 minutes. It runs without root and without capabilities, and opens no port. Its account, `submariner-route-watchdog`, may read Gateway objects and delete the route agent pod, nothing else. The token is in `/etc/submariner-route-watchdog/kubeconfig` (root only); systemd passes it to the service with `LoadCredential`. Log: `sudo journalctl -u submariner-route-watchdog`.
- Limits IPsec to the central gateway. The nftables table `inet submariner_hub`, loaded at boot by the unit `submariner-hub-firewall`, drops UDP 500, 4500 and 4490 to and from any other address, and all of it over IPv6. This blocks tunnels to other remote nodes, and to the central gateway node's own address. Ubuntu's `nftables` service is not used: its configuration would flush the Calico and Submariner rules. On a joined node the script recreates the gateway pod once.
- Labels the node `submariner.io/gateway=true`.

Then:

```bash
newgrp microk8s                      # or log out and in
kubectl get nodes
kubectl get apiservice v3.projectcalico.org
kubectl get ippools.projectcalico.org
kubectl auth can-i get secrets --namespace kube-system --as=any-user   # no
```

## 5) Join Submariner

Run the join stage of the checks from the credentials directory. It checks the cluster ID, the credential files (mode, CA, TLS to the broker, the token's owner and expiry, the PSK), MicroK8s and its authorization modes, the route watchdog, the IPsec firewall, the gateway label and the tool versions. The join stores the credentials in the node's cluster: do not join while "API authorization" or "kubelet authorization" fails.

```bash
cd ~/subm-creds
~/remote-node/preflight.sh --stage join
~/remote-node/join-submariner.sh
```

`join-submariner.sh`:

1. Reads and persists the cluster ID.
2. Checks that the values file's CIDRs match the live cluster.
3. Writes `local-values.yaml` with the ID and the three credentials.
4. Runs `helm upgrade --install` with `VALUES_FILE` and `local-values.yaml`.
5. Waits for the Submariner pods and prints `subctl show all`.

It warns when the route watchdog has no account; re-run `setup-microk8s.sh` then. The token is passed inline: the node must not use `brokerK8sSecret`, which would start a secret syncer its account may not run.

The same by hand:

```bash
helm repo add submariner-latest https://submariner-io.github.io/submariner-charts/charts
helm repo update
kubectl label node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" submariner.io/gateway=true --overwrite
helm upgrade --install submariner-operator submariner-latest/submariner-operator \
  --version 0.25.0 \
  --namespace submariner-operator --create-namespace \
  --set submariner.clusterId="$(cat cluster-id.txt)" \
  --set-string broker.token="$(cat broker-token.txt)" \
  --set-string broker.ca="$(cat broker-ca-base64.txt)" \
  --set-string ipsec.psk="$(cat broker-psk.txt)" \
  --values ~/remote-node/submariner-values.yaml
```

`subctl join` is not used: it needs a `broker-info.subm` file, which this setup does not have.

A few minutes later, on the node:

```bash
kubectl -n submariner-operator get pods   # operator, gateway, routeagent, lighthouse-agent, lighthouse-coredns, metrics-proxy: Running
subctl show connections                   # <central-cluster-id> ... 10.42.0.0/16, <central service CIDR>  connected
subctl show gateways                      # this node: active, "All connections (1) are established"
subctl diagnose all
kubectl get ippools.projectcalico.org     # two pools for the central CIDRs, disabled: true
```

On the central cluster:

```bash
subctl show connections                   # <cluster-id> ... 10.152.185.0/24, 10.3.0.0/16  connected
kubectl -n submariner-k8s-broker get clusters.submariner.io,endpoints.submariner.io
```

If the gateway log on the node shows the broker refusing an Endpoint or Cluster, the node advertises other CIDRs or another cluster ID than enrolled. Compare `cluster-id.txt` and the enrolled `SUBNETS` with `submariner-values.yaml`.

## 6) Check routing and clusterset DNS

Export a test Service from the node and reach it from the central cluster. The central cluster lets only the federation's controller reach remote pods, and only on TCP 5672. The test therefore resolves the name from a test pod and opens the TCP path from the controller.

The broker accepts only the exports in the node's record. On the central cluster, add the test Service to the record first; the list replaces the old one, so keep the worker Service:

```bash
kubectl -n submariner-k8s-broker patch configmap cluster-<id> --type merge \
  -p '{"data":{"exports":"federation-z/exareme2-test-workers-service,submariner-smoke/smoke-nginx"}}'
```

On the node:

```bash
kubectl apply -f ~/remote-node/smoke-test.yaml
kubectl -n submariner-smoke rollout status deploy/smoke-nginx
kubectl -n submariner-smoke get serviceexport smoke-nginx -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}'   # Valid=True, Ready=True
```

On the central cluster (the namespace is created outside Argo CD and removed afterwards):

```bash
kubectl create namespace submariner-smoke
kubectl -n submariner-smoke run dns --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'nslookup smoke-nginx.submariner-smoke.svc.clusterset.local'          # an address in 10.152.185.0/24
kubectl -n submariner-smoke run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -sS --max-time 5 http://smoke-nginx.submariner-smoke.svc.clusterset.local:8080 || echo denied'   # denied by the remote-clusters tier
kubectl -n federation-z exec deploy/exaflow-controller-deployment -- \
  python -c 'import socket,sys; s=socket.create_connection((sys.argv[1],5672),5); print("tcp 5672 open")' <remote worker pod IP>   # after step 8
```

Expected: the name resolves, the fetch is denied, and the controller reaches the remote worker on 5672 once the worker runs. Clean up, the node first, then restore the record:

```bash
kubectl delete -f ~/remote-node/smoke-test.yaml           # node
kubectl delete namespace submariner-smoke                 # central
kubectl -n submariner-k8s-broker patch configmap cluster-<id> --type merge \
  -p '{"data":{"exports":"federation-z/exareme2-test-workers-service"}}'   # central
```

## 7) Remove the credential files

On the node, once the connection is up:

```bash
shred -u ~/subm-creds/broker-token.txt ~/subm-creds/broker-ca-base64.txt ~/subm-creds/broker-psk.txt ~/subm-creds/local-values.yaml
```

Remove the enrollment output directory on the central side the same way. The node's cluster keeps the credentials in the Helm release Secret and in the `Submariner` resource; with RBAC only the cluster administrator and the Submariner accounts that need them can read them. Enroll and join again before the token expires.

## 8) Deploy the exaflow worker

The central side must already list `exareme2-test-workers-service.federation-z.svc.clusterset.local` in `controller.workers_dns` (`../mip-infrastructure/customizations/exareme2-values.yaml`) and export the aggregation server (`../mip-infrastructure/submariner-policies/service-exports.yaml`).

The controller fails its health check while any name in `workers_dns` does not resolve. Until the remote worker is exported and ready, the controller restarts on its startup probe (`0/1`, `NXDOMAIN` in its log). This is expected and stops once the worker is ready. The same happens whenever the remote worker disappears.

```bash
cd ~/remote-node
./deploy-worker.sh                       # first node: dataset synthetic_a
DATASET=synthetic_b ./deploy-worker.sh   # second node
```

The script:

- creates the namespace `federation-z` and the ConfigMap `synthetic-data` (`CDEsMetadata.json` and the CSV of `DATASET`);
- applies the worker, its headless Service, ServiceExport and NetworkPolicy, with the cluster ID as worker identifier;
- waits for the central imports and for the worker to become ready.

The worker reads its data only at start-up, so the script restarts it when the ConfigMap changes.

- The worker's NetworkPolicy (`exaflow-worker/networkpolicy.yaml`) admits only the central pod CIDR on TCP 5672. Outbound, it allows only DNS and the central aggregation server (TCP 50051 in the central service CIDR).
- The worker mounts no service-account token: it never calls the Kubernetes API, and the analysis code it runs gets no credential.

Check on the central cluster:

```bash
kubectl -n federation-z get serviceimport                                   # exareme2-test-workers-service
kubectl -n federation-z run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -sS http://exaflow-controller-service:5000/healthcheck && curl -sS http://exaflow-controller-service:5000/datasets_locations'
```

`datasets_locations` lists each dataset under the cluster ID of its node. A descriptive-statistics run on `synthetic_a`, from the MIP frontend or the controller API, completes the check.

For real data, replace the `csv-data` ConfigMap volume in `exaflow-worker/statefulset.yaml` with a hostPath or PersistentVolumeClaim that holds one directory per data model, mounted at `/opt/csvs`. Then run `deploy-worker.sh` again.

## Operations

- Running a script again is safe; each step checks the current state first.
- Health: run `./preflight.sh --stage health` on the node and `../enrollment/check-central.sh` on the central cluster after a reboot, an upgrade or a central change. The node's check covers:
  - the connection to the central cluster and the address it uses;
  - the gateway's policy routing, the networkd drop-in, the route watchdog and the IPsec firewall;
  - the authorization of the API server and the kubelet, and the controller manager's access to Calico tiers;
  - the worker's export (`Ready=True`), clusterset DNS, and a TCP connection to the aggregation server.

  DNS alone does not show a publishing failure, because names resolve from local copies. Each gateway reports only its own side, so one can show `connected` and the other `error`.
- Credential rotation: run `enroll-remote.sh CLUSTER_ID=<id>` again with the same `SUBNETS` and `EXPORTS`, copy the new files, and run `join-submariner.sh`; Helm upgrades in place. `ROTATE_IDENTITY=true` also invalidates all earlier tokens of the account.
- Allowed exports: the node may publish only the services in the `exports` entry of its record, the ConfigMap `cluster-<id>` in `submariner-k8s-broker`. Change it as in step 6, then run `../enrollment/verify-enrollment.sh CLUSTER_ID=<id> IMPERSONATE=true` (no token needed). Delete the ServiceExport on the node before you remove its entry.
- MicroK8s follows its snap track and gets patch releases automatically. Another track means a reinstall (`reset-node.sh`, new channel).
- The Calico API server certificate expires after 365 days. Delete the Secret `calico-apiserver-certs` in `calico-apiserver` and run `setup-microk8s.sh` again.
- MicroK8s certificates still expire. `sudo microk8s refresh-certs -c` shows their validity. Renew in a maintenance window with `sudo microk8s refresh-certs -e server.crt` and `-e front-proxy-client.crt`; the control plane restarts.

### Upgrade Submariner

Upgrade the central cluster and all nodes in one maintenance window. The version is pinned in `common/submariner/operator/kustomization.yaml` and as `SUBMARINER_VERSION` in `setup-tools.sh`, `preflight.sh` and `join-submariner.sh`; Renovate moves them together.

1. Apply any change to the out-of-band RBAC.
2. Let Argo CD sync the central chart. The operator updates the CRDs and restarts the gateway, the route agent and Lighthouse.
3. Run `../enrollment/check-central.sh`.
4. On every node: take a VM snapshot, copy the updated directory, and run with the node's own `VALUES_FILE` and `DATASET` (node 2: `submariner-values-node2.yaml`, `synthetic_b`):
   - `sudo ./setup-tools.sh` for the matching `subctl`;
   - `./join-submariner.sh` from a directory without credential files, which upgrades the release with its stored credentials;
   - `./deploy-worker.sh`;
   - `./preflight.sh --stage health`.
5. Check `subctl show versions` and `subctl show connections` on the node and the central cluster, and run `check-central.sh` again.

Notes:

- The Lighthouse agent and CoreDNS can restart once when they start before the operator has updated the MCS CRDs (`error getting REST mapper` for `v1beta1`). The central controller can restart once while a tunnel is down (step 8).
- Across a libreswan major version (Submariner 0.21 to 0.24) the tunnels stay `connecting` until the node runs the new version. 0.24 and 0.25 both use libreswan 5, so a node on 0.24 keeps working until its upgrade. On a 0.24 node, `deploy-worker.sh` stops at the `v1beta1` ServiceExport; run it after the node's upgrade.
- Remove the smoke-test namespaces on both sides first, or the leftover export shows up in every agent log.

## Add another remote node

Every node has its own CIDRs, cluster ID, values file and dataset; the scripts are shared. The second node of federation-Z uses `10.4.0.0/16`, `10.152.186.0/24`, `submariner-values-node2.yaml` and the dataset `synthetic_b`.

1. In the repository:
   - add the node's pod CIDR as an `ipBlock` to every rule of `../mip-infrastructure/submariner-policies/network-policy.yaml`;
   - add its pod and service CIDR as an entry of `../mip-infrastructure/remote-networks.yaml`;
   - add a copy of `submariner-values.yaml` with the node's CIDRs (`submariner-values-<node>.yaml`);
   - add the node's CSV to `exaflow-worker/data/synthetic_v_0_1/`, with its dataset code in `CDEsMetadata.json`.

   CI (`scripts/check-remote-cidrs.sh`) checks that the CIDRs agree. Merge, and let Argo CD sync `netpol-federation-z-remote` and the federation's `submariner-network-policy` before the join.
2. Enroll the node with its CIDRs and its own output directory:

   ```bash
   cd deployments/hybrid/federations/federation-Z/enrollment
   ./enroll-remote.sh SUBNETS=10.4.0.0/16,10.152.186.0/24 OUT_DIR=~/subm-creds-node2 BROKER_URL=https://<broker-api-host>:6443
   ./verify-enrollment.sh OUT_DIR=~/subm-creds-node2
   ```

3. Copy `remote-node/` and the credential files to the node, then run the node steps with its CIDRs:

   ```bash
   cd ~/remote-node
   IPv4_CLUSTER_CIDR=10.4.0.0/16 IPv4_SERVICE_CIDR=10.152.186.0/24 ./preflight.sh
   sudo ./setup-tools.sh
   sudo IPv4_CLUSTER_CIDR=10.4.0.0/16 IPv4_SERVICE_CIDR=10.152.186.0/24 ./setup-microk8s.sh
   newgrp microk8s
   cd ~/subm-creds
   IPv4_CLUSTER_CIDR=10.4.0.0/16 IPv4_SERVICE_CIDR=10.152.186.0/24 ~/remote-node/preflight.sh --stage join
   VALUES_FILE=~/remote-node/submariner-values-node2.yaml ~/remote-node/join-submariner.sh
   ```

   A node behind NAT needs nothing else: it opens the tunnel, and the gateway discovers its public address.
4. Steps 6 and 7 as for the first node.
5. Step 8 with the node's dataset: `DATASET=synthetic_b ./deploy-worker.sh`.

Datasets and metadata:

- Every node serves a different CSV; the controller drops a dataset code that two workers serve.
- All nodes must carry the byte-identical `CDEsMetadata.json`. With two versions the UI shows only the datasets of the node that registered first. When the file changes, run `deploy-worker.sh` on every node right away.
- `controller.workers_dns` does not change: all nodes export the same Service name, and the clusterset name resolves to every ready remote worker.

The remote gateways also try tunnels to each other, because Submariner connects every gateway to every other one. The IPsec firewall blocks them, and the worker's NetworkPolicy admits only the central networks. Only the connections to the central cluster matter; the gateway logs still show the attempts.

## Remove a remote node

On the node:

```bash
kubectl delete -k ~/remote-node/exaflow-worker/ --ignore-not-found
kubectl delete -f ~/remote-node/smoke-test.yaml --ignore-not-found
kubectl -n submariner-operator delete submariner submariner
kubectl -n submariner-operator wait --for=delete submariner/submariner --timeout=300s
helm uninstall submariner-operator -n submariner-operator
kubectl delete namespace submariner-operator
kubectl delete crd $(kubectl get crd -o name | grep -E 'submariner\.io|multicluster\.x-k8s\.io' | sed 's|.*/||')
kubectl label node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" submariner.io/gateway-
```

`subctl uninstall --yes` does the same in one step; `reset-node.sh` resets the whole node. Deleting the namespace also deletes the route watchdog's account: before the node joins again, run `sudo ./setup-microk8s.sh` again.

On the central cluster:

```bash
deployments/hybrid/federations/federation-Z/enrollment/revoke-remote.sh CLUSTER_ID=<cluster-id>
subctl show connections            # the node is gone
```

`revoke-remote.sh` deletes the account (its tokens stop working), its bindings and record, and the node's Cluster, Endpoint, EndpointSlice and ServiceImport objects on the broker. For a node without a `cluster-<id>` account, delete its broker objects by hand:

```bash
ID=<cluster-id>
kubectl -n submariner-k8s-broker delete clusters.submariner.io "$ID" --ignore-not-found
kubectl -n submariner-k8s-broker delete endpoints.submariner.io -l submariner-io/clusterID="$ID"
kubectl -n submariner-k8s-broker delete serviceimports.multicluster.x-k8s.io,endpointslices -l submariner-io/clusterID="$ID"
```

Then remove the node's CIDRs from `remote-networks.yaml` and `submariner-policies/network-policy.yaml`.

## Troubleshooting

### `x509: certificate signed by unknown authority`

`broker.ca` must be the base64 string, not PEM. Check from the node:

```bash
base64 -d broker-ca-base64.txt > broker-ca.crt
openssl s_client -connect <broker-api-host>:6443 -CAfile broker-ca.crt -verify_hostname <broker-api-host> < /dev/null 2>/dev/null | grep 'Verify return code'
# expected: Verify return code: 0 (ok)
```

Then update the release:

```bash
helm upgrade submariner-operator submariner-latest/submariner-operator --namespace submariner-operator --reuse-values --version 0.25.0 \
  --set-string broker.ca="$(cat broker-ca-base64.txt)"
```

### The broker refuses the node's objects

The message names the admission policy:

- `submariner-remote-cluster-ownership` or `-subnets`: the node advertises another cluster ID or other subnets than enrolled. `cluster-id.txt` must match the account of the token (`preflight.sh --stage join` checks it), and the CIDRs in `submariner-values.yaml` must lie within the enrolled `SUBNETS`. Enroll again or fix the values file, then join again.
- `submariner-remote-cluster-exports`: the node publishes a service that is not in its record. The ServiceExport does not become `Ready`; its status and the Lighthouse agent log name the service and the recorded exports. Add the service to the record (step 6) or delete the ServiceExport. "Parameters not found" means that the central cluster has no record for the node.

### The tunnel stays `connecting`

- IKE fails on both sides with authentication errors: the PSK differs. Use `.data.psk` as stored, not decoded. Compare `sha256sum broker-psk.txt` with `kubectl -n submariner-operator get secret submariner-ipsec-psk -o jsonpath='{.data.psk}' | sha256sum` on the central cluster.
- No IKE answer: UDP 4500 or 4490 to the gateway address is blocked, or the gateway found a wrong public IP. Check `kubectl -n submariner-operator logs ds/submariner-gateway`; set the public IP with `kubectl annotate node <node> gateway.submariner.io/public-ip=ipv4:<ip>`.
- The central side shows the connection, the node does not: the central gateway Service answers only on the node that runs the gateway pod. Check `subctl show gateways` on the central cluster.
- The node accepts IPsec only from `CENTRAL_GATEWAY_IP`. If the central address changed, or the gateway Service lacks UDP 4500 or 4490 (`check-central.sh` checks both), the tunnel stays `connecting`. `./preflight.sh --stage health` shows the address in use. Correct `central.env` and run `setup-microk8s.sh` again; it reloads the firewall and recreates the gateway pod.

### The connection shows `error` while the tunnel is up

`subctl show connections` reports `error` with `Failed to successfully ping the remote endpoint IP`, the IPsec SAs are established, and `ip route show table 150` on the node is empty; `ip rule show` may have lost `lookup 150` too.

The route agent installs this rule and these routes (remote CIDRs, source = the node's Calico address) once. Host traffic, the gateway's health check included, needs them to enter the tunnel. Without them the pings fail while pod traffic still flows. Lighthouse then stops answering for that cluster: the worker gets `NXDOMAIN` for central names, and the central controller restarts (step 8). If `ping -I <Calico address> <remote health-check address>` works while a plain ping fails, this is the cause.

Causes:

- A systemd-networkd restart (for example after an unattended upgrade) deletes the rule and routes as foreign. The drop-in of `setup-microk8s.sh` prevents this. `journalctl -u systemd-networkd` and `/var/log/apt/history.log` show when it happened.
- With a DHCP uplink, a networkd restart removes and adds the interface address, and the kernel drops every route through it. No networkd setting prevents this on Ubuntu 24.04.

The route watchdog repairs both within about two minutes; `sudo journalctl -u submariner-route-watchdog` lists each loss. By hand: `kubectl -n submariner-operator delete pod -l app=submariner-routeagent`. On the central cluster, two DaemonSets do the same on the gateway node ([common/submariner/README.md](../../../../../common/submariner/README.md), "Gateway node").

### The node keeps an old central endpoint

When the central gateway moves to another node, the broker gets a new central Endpoint. A node can keep the old one: its connection stays `connecting` or `error`, and the central gateway logs `Received NAT discovery packet for endpoint "...-<old address>-v4", but we are endpoint "...-<new address>-v4"`.

- Check: `./preflight.sh --stage health` prints the central endpoint the node holds. Compare it with `kubectl -n submariner-k8s-broker get endpoints.submariner.io` on the central cluster.
- Fix: `kubectl -n submariner-operator delete pod -l app=submariner-gateway`.

### `clusterset.local` names do not resolve

- Imports arrive only in namespaces that exist on the node. Right after the join `federation-z` does not exist yet, so the central names do not resolve, and the agent logs `Unable to distribute resource ... due to missing namespace "federation-z"`. This is expected; step 8 creates the namespace.
- `kubectl -n kube-system get configmap coredns -o yaml` must contain a `clusterset.local` block that forwards to the Lighthouse CoreDNS. Re-enabling the MicroK8s `dns` addon removes it; restart `submariner-operator` to add it again.
- Repeated `x509` errors in `kubectl -n submariner-operator logs deploy/submariner-lighthouse-agent`: the broker CA is wrong (see above).
- `kubectl get serviceexport -A -o yaml` must show `Valid=True` and `Ready=True`. A `False` condition names the cause, typically a missing Service.
- On the central cluster the ServiceImport appears in the exporting namespace. If it does not, read `kubectl -n submariner-operator logs deploy/submariner-lighthouse-agent` on both sides.

### The node came back under another name

After a snapshot restore or an instance rename, `kubectl get nodes` shows two nodes with the same address. The original is `NotReady` and still labelled `submariner.io/gateway=true`. The new one, named after the instance, has `calico-node` in `CrashLoopBackOff` ("is already using the IPv4 address"). The pods stay bound to the dead node, and the tunnel is down. Cloud-init set the host name from the instance name. Restore the name, pin it, and let the kubelet register again:

```bash
sudo hostnamectl set-hostname <original node name>
sudo sed -i 's/<new instance name>/<original node name>/g' /etc/hosts
printf 'preserve_hostname: true\n' | sudo tee /etc/cloud/cloud.cfg.d/99-microk8s-preserve-hostname.cfg
sudo microk8s stop && sudo microk8s start
kubectl delete node <new instance name>
kubectl get nodes; kubectl -n submariner-operator get pods; subctl show connections
```

The original node turns `Ready`, the pods are recreated and the tunnel comes back. The alternative is to rename the instance back in the provider console.

### Calico reports the node address on `vx-submariner`

`kubectl get node -o jsonpath='{.items[0].metadata.annotations.projectcalico\.org/IPv4Address}'` returns an address in `240.0.0.0/8`, and the calico-node log says `IPv4 address has changed`. Calico's default detection took the tunnel interface. Run `setup-microk8s.sh` again, or by hand:

```bash
kubectl -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
sudo sed -i '/name: IP_AUTODETECTION_METHOD/{n;s|value: ".*"|value: "kubernetes-internal-ip"|}' /var/snap/microk8s/current/args/cni-network/cni.yaml
sudo touch /var/snap/microk8s/current/var/lock/no-cert-reissue
```

The last command stops MicroK8s from re-issuing its certificates, and restarting the control plane, whenever a host address appears or disappears. That happens at every join and reboot.

### A flow is denied on the central side

The Calico policy `remote-clusters.federation-z` denies everything from the node's networks except the two allowed flows into `federation-z`. The NetworkPolicies of `federation-z` then allow only those ports from the listed `ipBlock`s. Check that the node's CIDRs are an entry of `../mip-infrastructure/remote-networks.yaml` and that its pod CIDR is in `submariner-policies/network-policy.yaml`. `../enrollment/check-central.sh` compares both with the cluster.

### `preflight.sh` fails on "API authorization" or "kubelet authorization"

- "API authorization": the API server allows every authenticated request (`AlwaysAllow` in `/var/snap/microk8s/current/args/kube-apiserver`; `microk8s status` shows `rbac` disabled). Any pod can then read the broker token and the PSK.
- "kubelet authorization": the kubelet allows every authenticated request on port 10250 (`/var/snap/microk8s/current/args/kubelet` has no `Webhook`). Any token that reaches the port can run commands in every pod.
- Fix: take a VM snapshot and run `sudo ./setup-microk8s.sh` with the node's CIDRs. One control-plane restart applies both modes. The API is gone for about a minute. Pods that hold a leader lease, such as the Submariner operator, can restart once, and the worker can be not ready for up to a minute. Then run `./preflight.sh --stage health` and `../enrollment/check-central.sh`.
- The files say `RBAC,Node` and `Webhook` but a check still fails: the running control plane predates the change. Run `sudo snap restart microk8s.daemon-kubelite`.
- The script stops before the change when the kubelet certificate names another host than the registered node. Restore the host name first (see "The node came back under another name"). It also stops when the API server's client certificate for the kubelet is not in `system:masters`, because `kubectl logs` and `kubectl exec` would then fail.
- Do not run `microk8s disable rbac`: it restores `AlwaysAllow` and deletes the default roles.
- While the mode was `AlwaysAllow`, every pod could read the credentials. If an untrusted workload ran on the node then, rotate the node's token with `ROTATE_IDENTITY=true` (Operations).

### A component logs `forbidden` after RBAC was enabled

- The message names the account, verb and resource. An account `cluster-<id>` of `submariner-k8s-broker` refers to the central broker: the node's account may not list Secrets there, by design, and the gateway logs that refusal repeatedly.
- What an account may do: `kubectl auth can-i --list --as=system:serviceaccount:submariner-operator:<account> --namespace submariner-operator`.
- The Calico API server logs `user cannot get tier` for `system:kube-controller-manager`, and the garbage collector never syncs (`journalctl -u snap.microk8s.daemon-kubelite`): the role `calico-tier-getter` is missing. Run `setup-microk8s.sh` again; no restart is needed.
- Refusals that name `system:auth-delegator` or `/healthz` in the first seconds after RBAC is enabled stop by themselves.
- The Submariner roles come from the chart: `kubectl get clusterrole,clusterrolebinding | grep submariner` and `kubectl -n submariner-operator get role,rolebinding`. If one was deleted, run `./join-submariner.sh` from a directory without credential files. `setup-microk8s.sh` re-applies the Calico API server's roles and `calico-tier-getter`.
- A client that calls the kubelet directly on port 10250, such as a metrics scraper, needs a role on `nodes/metrics`, `nodes/stats` or `nodes/proxy`. Nothing in this runbook does.

### The route agent cannot create IP pools

`kubectl -n submariner-operator logs ds/submariner-routeagent` reports `ippools.projectcalico.org` errors: the Calico API server is not available. Check `kubectl get apiservice v3.projectcalico.org` and `kubectl -n calico-apiserver get pods`, and run `setup-microk8s.sh` again.

### `subctl` reports a version mismatch

Run `setup-tools.sh` again with the deployed `SUBMARINER_VERSION`.

### The central controller finds no workers

One name in `controller.workers_dns` that does not resolve stops the discovery of all workers, the central ones included. Check `kubectl -n federation-z logs deploy/exaflow-controller-deployment | grep -i -E 'NXDOMAIN|WorkerLandscapeAggregator'`, and make sure the remote ServiceExport is published.

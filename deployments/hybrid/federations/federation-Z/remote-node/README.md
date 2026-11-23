# Submariner Remote Node Setup for Federation-Z

This guide installs MicroK8s with the chosen IPv4 CIDRs on a fresh Ubuntu 24.04 node, joins the node to the central Submariner broker with Helm under an identity enrolled on the central cluster, verifies the connection, and deploys an exareme2 (exaflow) worker that the central controller discovers through the clusterset DNS.

The central side (broker, operator, controller, network policies, ServiceExports, per-node enrollment) is managed from `../mip-infrastructure/`, `../enrollment/` and `common/submariner/`. Nothing on the remote node is managed by Argo CD; everything here is applied with the scripts in this directory. Background and design notes: [docs/hybrid-federations.md](../../../../../docs/hybrid-federations.md).

## Topology

| Side | Component | Where defined |
| --- | --- | --- |
| Central (RKE2) | Submariner broker namespace and operator, chart 0.25.0, gateway on a LoadBalancer address | `common/submariner/` |
| Central | Per-node broker accounts, admission policies, enrollment scripts | `base/mip-infrastructure/rbac/submariner-remote-admission.yaml`, `../enrollment/` |
| Central | exaflow controller, aggregation server, remote allow policies, ServiceExports | `../mip-infrastructure/` |
| Central | Calico tier denying the remote CIDRs, each passed only to its own federation | `common/security/remote-clusters/`, `common/security/remote-networks/`, `../mip-infrastructure/remote-networks.yaml` |
| Remote (this node) | Single-node MicroK8s with RBAC authorization, Calico with VXLAN, Calico API server, Submariner operator via Helm | `setup-microk8s.sh`, `join-submariner.sh`, `submariner-values.yaml` |
| Remote | exaflow local worker, headless Service `exareme2-test-workers-service`, ServiceExport | `exaflow-worker/`, `deploy-worker.sh` |

Only the remote node initiates the IPsec tunnel to the central gateway (`natEnabled: true`, no LoadBalancer on the remote). The central controller resolves `exareme2-test-workers-service.federation-z.svc.clusterset.local` to the worker pod address and dials it on port 5672 across the tunnel; the worker reaches the central aggregation server on `exaflow-aggregation-service.federation-z.svc.clusterset.local:50051`. Every other flow between the clusters is denied on the central side. That includes the controller's HTTP API and the Flower server: the API is unauthenticated, so remote nodes do not reach it, and Flower algorithms do not run on remote workers.

## Parameters

| Parameter | Default | Used by | Notes |
| --- | --- | --- | --- |
| `SUBMARINER_VERSION` | `0.25.0` | `setup-tools.sh`, `join-submariner.sh`, `preflight.sh` | Must equal the chart version in `common/submariner/operator/kustomization.yaml`; subctl is pinned to the same version and checked against the release's SHA-256 list |
| `MICROK8S_CHANNEL` | `1.33/stable` | `setup-microk8s.sh` | A supported Kubernetes minor close to the central cluster's (1.34 at the time of writing); Submariner does not require the two clusters to match |
| `IPv4_CLUSTER_CIDR` | `10.3.0.0/16` | `setup-microk8s.sh`, the node's values file, enrollment `SUBNETS` | Pod CIDR; must not overlap the central pod CIDR (`10.42.0.0/16`), the central service CIDR or another remote node |
| `IPv4_SERVICE_CIDR` | `10.152.185.0/24` | `setup-microk8s.sh`, the node's values file, enrollment `SUBNETS` | Service CIDR; same rule |
| `VALUES_FILE` | `submariner-values.yaml` | `join-submariner.sh` | The node's values file; one file per node because the CIDRs are literals (`submariner-values-node2.yaml` for the second node). The join refuses a file whose CIDRs differ from the live cluster |
| `DATASET` | `synthetic_a` | `deploy-worker.sh` | CSV of `exaflow-worker/data/synthetic_v_0_1/` this node serves; every node serves a different one |
| `CENTRAL_GATEWAY_IP` | from `central.env` | `setup-microk8s.sh`, `preflight.sh` | The central gateway's LoadBalancer address, the only IPsec peer the node accepts. Must equal the address pinned on the central cluster (`common/submariner/operator/kustomization.yaml`) and the one in the hardening inventory |
| Cluster ID | `rn-<8 hex>`, chosen at enrollment | `enroll-remote.sh`, `join-submariner.sh`, `deploy-worker.sh` | Name suffix of the broker account `cluster-<id>`; travels in `cluster-id.txt`. Record it, with the token expiry and the site, in the internal mapping; it is not stored in this repository |
| `TOKEN_DURATION` | `8760h` | `enroll-remote.sh` | Lifetime of the bound token; re-enroll and re-join before it ends |
| `EXPORTS` | `federation-z/exareme2-test-workers-service` | `enroll-remote.sh` | Services the node may publish to the clusterset, as comma-separated `<namespace>/<service>`; the default is read from `exaflow-worker/serviceexport.yaml`. The broker refuses every other export of the node |
| `broker.server` | value in `submariner-values.yaml` | `join-submariner.sh`, `preflight.sh` | Central API server `<broker-api-host>:6443`; the only real endpoint in this directory |

Changing the CIDRs after installation requires `snap remove --purge microk8s` and a new enrollment (the CIDRs are pinned per account); changing the cluster ID requires the removal procedure below.

## Prerequisites

- Ubuntu 24.04 LTS amd64 with sudo, 2 vCPU, 4 GB RAM, 40 GB disk; time synchronised.
- A hostname that differs from every node name of the central cluster and that stays the same across reboots. Cloud images let cloud-init reset it from the instance name at every boot; `setup-microk8s.sh` pins it (`preserve_hostname: true`). A node that boots under another name registers as a second node and strands the gateway and the worker on the old one (see Troubleshooting).
- Outbound access from the node: TCP 6443 to `<broker-api-host>`; UDP 4500 and UDP 4490 to `<gateway-public-ip>`; TCP 443 to `api.snapcraft.io`, `quay.io`, `registry-1.docker.io`, `github.com`, `raw.githubusercontent.com`, `submariner-io.github.io`, `api.ipify.org`.
- Inbound UDP 4500 and 4490 from `<gateway-public-ip>` are optional; one-way reachability suffices because this node initiates the tunnel.
- On the central cluster: `kubectl` with cluster-admin for the enrollment (steps 1 and 7), the out-of-band files `base/mip-infrastructure/rbac/submariner-rbac.yaml` and `submariner-remote-admission.yaml` applied, the federation's remote allow policies and the cluster-wide deny synced with the node's CIDRs, and `subctl` at the pinned version for the verification commands.
- On the central cluster, a healthy Submariner side: `../enrollment/check-central.sh` passes (gateway node labelled and active, Calico API server available, broker lists the central cluster, PSK in the operator namespace only, admission policies present, the tier policy assigning the remote networks to `federation-z`, policy Applications synced). The two checks that fail after a node redeploy are the gateway label and the Calico API server; both belong to the cluster installation (see `docs/hybrid-federations.md`).
- A VM snapshot before each step that changes the node (steps 0, 4, 5 and 8).

Copy this directory to the node before starting, for example:

```bash
scp -r deployments/hybrid/federations/federation-Z/remote-node <user>@<remote-node>:remote-node
```

## 0) Reset a reused node (only when the node carries an earlier attempt)

`preflight.sh` reports an installed MicroK8s snap. If the node is not fresh, return it to a clean state and reboot:

```bash
sudo ./reset-node.sh --reboot
```

The script removes the microk8s snap and its data, old helm and kubectl snaps (MicroK8s provides both), subctl, the MicroK8s kubeconfig and Helm caches of the invoking user, the persisted cluster ID, leftover credential files, and the Submariner and Calico network state. Afterwards, revoke the node's previous identity on the central cluster (`../enrollment/revoke-remote.sh CLUSTER_ID=<previous id>`), or delete the stale broker objects by hand when the previous attempt predates enrollment (section "Removing a remote node").

## 1) Enroll the node on the central cluster

Enrollment creates the node's broker account `cluster-<id>`, binds it to the Role `submariner-remote-cluster`, records the node's CIDRs for the subnet policy and the service it may publish for the export policy, issues a bound token and collects the broker CA and the IPsec PSK. Run it on a machine with cluster-admin `kubectl` for the central cluster:

```bash
cd deployments/hybrid/federations/federation-Z/enrollment
./enroll-remote.sh SUBNETS=10.3.0.0/16,10.152.185.0/24 OUT_DIR=~/subm-creds BROKER_URL=https://<broker-api-host>:6443
./verify-enrollment.sh OUT_DIR=~/subm-creds
```

`enroll-remote.sh` prints the cluster ID and the token expiry; record both with the site in the internal mapping. Pass `CLUSTER_ID=<id>` to re-enroll or rotate an existing node, with the same `SUBNETS` and `EXPORTS` as before: a re-run rewrites the record, and the script warns when the record changes. A run without `CLUSTER_ID` creates a new account every time (revoke unused ones with `revoke-remote.sh`). By default the record allows one export, the worker Service of `exaflow-worker/serviceexport.yaml`; `EXPORTS=<namespace>/<service>,...` sets another list. `verify-enrollment.sh` uses only the issued token: it must be able to create its own broker objects (server-side dry run), must be denied for another cluster's ID, for subnets outside the enrolled list and for a service outside the enrolled exports, and must be forbidden to read secrets. From a machine that reaches the API server through the SSH SOCKS tunnel of `docs/remote-access.md`, the script picks `socks5://127.0.0.1:1080` up on its own; `PROXY_URL` overrides it.

The output directory holds:

| File | Content | Passed to the chart as |
| --- | --- | --- |
| `cluster-id.txt` | the enrolled cluster ID | `submariner.clusterId` |
| `broker-token.txt` | bound token of `cluster-<id>`, plain | `broker.token` (the chart writes it unchanged into the `Submariner` resource) |
| `broker-ca-base64.txt` | broker CA, base64 | `broker.ca` (a base64 string; the components decode it themselves) |
| `broker-psk.txt` | `.data.psk` of `submariner-ipsec-psk` as stored (base64) | `ipsec.psk`. The central gateway mounts the PSK secret and base64-encodes the bytes before use; the Helm value is used as is, so both sides agree only on the stored string |
| `broker-ca.crt`, `broker-url.txt`, `subnets.txt`, `exports.txt`, `token-expiry.txt` | PEM CA, API URL, recorded subnets and exports, expiry | used by `verify-enrollment.sh` and for the record |

Transfer the files to the node over SSH and remove the local copies once the join is verified:

```bash
ssh <user>@<remote-node> 'umask 077 && mkdir -p subm-creds'
scp -p ~/subm-creds/cluster-id.txt ~/subm-creds/broker-token.txt ~/subm-creds/broker-ca-base64.txt ~/subm-creds/broker-psk.txt <user>@<remote-node>:subm-creds/
```

The files let their holder register this node's identity on the broker and join the clusterset. Keep them under `umask 077`, transfer them only over SSH, and shred them after use (step 7). If they leak, `revoke-remote.sh` invalidates them.

## 2) Pre-flight checks on the node

```bash
cd ~/remote-node
./preflight.sh
```

The install stage checks the OS, memory and disk, snapd, time synchronisation, resolution of and TCP reachability to the broker API, the route to the central gateway's LoadBalancer address, HTTPS egress to the download sources, the kernel modules Submariner needs (`esp4`, `xfrm_user`, `vxlan`, `ip_set`), that UDP 500/4500/4490/4800 are unbound, and that the remote CIDRs overlap neither the central CIDRs nor the node addresses. UDP reachability of the gateway cannot be probed without a peer; it is confirmed after the join by `subctl show connections`. Fix every `FAIL` before continuing; `WARN` lines are informational.

## 3) Bootstrap tools on the fresh Ubuntu VM

```bash
sudo ./setup-tools.sh
```

What it does:

- Installs `ca-certificates`, `curl`, `jq`, `openssl`, `python3`, `xz-utils`, `netcat-openbsd` and, when missing, `snapd`.
- Installs `subctl` pinned to `SUBMARINER_VERSION` in `/usr/local/bin` from the release asset. `subctl` must match the Submariner version of the broker; an unpinned "latest" subctl can be newer than the deployed version.

kubectl and helm are not installed here. MicroK8s provides both in the next step, so the Helm version stays the one bundled with the Kubernetes release (a snap-installed Helm would now be Helm 4).

## 4) Install MicroK8s with custom IPv4 CIDRs

```bash
sudo MICROK8S_CHANNEL=1.33/stable IPv4_CLUSTER_CIDR=10.3.0.0/16 IPv4_SERVICE_CIDR=10.152.185.0/24 ./setup-microk8s.sh
```

What the script does:

- Validates the CIDRs and writes `/var/snap/microk8s/common/.microk8s.yaml` (launch configuration `0.2.0`: `extraKubeAPIServerArgs` with `--authorization-mode=RBAC,Node`, `extraKubeletArgs` with `--authorization-mode=Webhook`, `extraCNIEnv`, `extraSANs` with the first service address, `dns` addon).
- Installs MicroK8s from `MICROK8S_CHANNEL` and waits for the node, Calico and CoreDNS to be ready. When MicroK8s is already installed it verifies the channel and the live CIDRs instead.
- Turns on RBAC authorization in the API server. MicroK8s starts with `--authorization-mode=AlwaysAllow`, under which every authenticated request is allowed: the service-account token of any pod, the worker's included, has full control of the cluster and reads the broker token and the IPsec PSK kept in the Helm release Secret and in the `Submariner` resource. A new installation starts with `RBAC,Node` from the launch configuration. On an installation that still runs `AlwaysAllow`, the script checks that the kubelet certificate carries the node's name and runs `microk8s enable rbac`, which restarts the control plane once: the API does not answer for about a minute, while the pods, the tunnel and cluster DNS keep running. It then verifies on the running server that an identity without a role is refused. One role is added, with the Calico API server (below). Nothing else has to be granted: the Submariner chart, Calico, the Calico API server and CoreDNS ship the roles of their service accounts, and the MicroK8s admin kubeconfig used by `kubectl`, `helm`, `subctl` and the route watchdog belongs to the group `system:masters`, which RBAC does not restrict.
- Sets the kubelet's authorization mode to `Webhook`. The kubelet serves its own API on port 10250 and accepts service-account tokens there. By default it allows every authenticated request, so a pod that reaches the port could run commands in every container of the node, the gateway included, even with RBAC on the API server. With `Webhook` the kubelet asks the API server, where RBAC decides; the API server keeps its own access for logs and exec through a certificate in `system:masters`. A new installation gets the argument from the launch configuration. On an existing one the script writes it to `/var/snap/microk8s/current/args/kubelet`; the restart that enables RBAC applies it, and when RBAC is already on the script restarts the control plane once for it. It then verifies that the running kubelet answers 403 to a token without a role and that `kubectl logs` still works.
- Creates the `kubectl` and `helm` aliases (`microk8s.kubectl`, `microk8s.helm3`), adds the invoking user to the `microk8s` group and writes its kubeconfig.
- Installs the Calico API server for the Calico version MicroK8s ships (needed by the Submariner route agent to create IP pools), generates its TLS certificate (365 days) when absent, patches the `APIService` CA bundle and waits until `v3.projectcalico.org` is available. It then grants the kube-controller-manager the right to read Calico tiers (ClusterRole and ClusterRoleBinding `calico-tier-getter`, the upstream names). The Calico API server answers a request for policies only when the caller may also read their tier. Without the role, RBAC lets the controller manager list the policies but Calico refuses them, its informers never sync, and the garbage collector and the quota controller report a failed sync at every period. Calico's own manifests carry the role from a later 3.29 release on; MicroK8s 1.33 ships 3.29.3.
- Pins Calico's IP autodetection to `kubernetes-internal-ip` and disables the automatic MicroK8s certificate re-issue on host address changes (`/var/snap/microk8s/current/var/lock/no-cert-reissue`). Both react to the `vx-submariner` interface the route agent adds at join time: Calico's default `first-found` would move the node IP to it, and MicroK8s would re-issue the API server certificate and restart the control plane, CoreDNS included, while the Submariner pods start.
- Writes the systemd-networkd drop-in `/etc/systemd/networkd.conf.d/10-submariner-foreign-routes.conf` (`ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no`). networkd deletes routes and routing policy rules it does not own at every start, which removes the policy routing the Submariner route agent installs on the gateway node (see Troubleshooting, "Connection shows `error` while the IPsec SAs are established").
- Installs the route watchdog: the service `submariner-route-watchdog` and its script `/usr/local/sbin/submariner-route-watchdog`. Every minute it compares table 150 with the subnets of the remote Endpoints. After two failed checks in a row it deletes the route agent pod, which re-installs the rule and the routes; at most one restart per 15 minutes. It covers the losses the drop-in cannot prevent (see the same Troubleshooting section). It runs without root and without capabilities, reads the MicroK8s admin kubeconfig through the MicroK8s group, opens no port and logs to the journal (`sudo journalctl -u submariner-route-watchdog`).
- Limits IPsec to the central gateway. An nftables table (`inet submariner_hub`, loaded at boot by the unit `submariner-hub-firewall`) drops UDP 500, 4500 and 4490 to and from any address other than `CENTRAL_GATEWAY_IP`, and all of it over IPv6. This blocks tunnels to other remote nodes (Submariner connects every gateway to every other one) and to the central gateway node's own address. The tunnel therefore uses the LoadBalancer address, which follows the gateway when the provider moves it. Ubuntu's `nftables` service is not used: its configuration flushes the Calico and Submariner rule sets. On a joined node, the script recreates the gateway pod once so it reconnects through that address.
- Labels the node `submariner.io/gateway=true`.

After the script completes:

```bash
newgrp microk8s                      # or log out and back in
kubectl get nodes
kubectl get apiservice v3.projectcalico.org
kubectl get ippools.projectcalico.org
kubectl auth can-i get secrets --namespace kube-system --as=any-user   # no: RBAC refuses an identity without a role
```

## 5) Join Submariner with Helm

Run the join stage of the pre-flight checks from the credentials directory. It verifies the enrolled cluster ID, the credential files (mode, CA decodes to a certificate, TLS to the broker verifies with that CA, the token's subject is the node's account and it has not expired, the token lists the broker's clusters, the PSK is base64 text), MicroK8s and its settings (authorization of the API server and of the kubelet included), the gateway label and the tool versions. The join stores the credentials in the node's cluster, so do not join while the "API authorization" or the "kubelet authorization" check fails.

```bash
cd ~/subm-creds
~/remote-node/preflight.sh --stage join
~/remote-node/join-submariner.sh
```

`join-submariner.sh` reads the enrolled cluster ID, persists it on the node, checks that the CIDRs of the values file are those of the live cluster (Calico IP pool and ServiceCIDR), writes `local-values.yaml` with the ID and the three credentials, adds the chart repository, runs `helm upgrade --install` with the node's values file (`VALUES_FILE`, default `submariner-values.yaml`) and `local-values.yaml`, waits for the operator, gateway, route agent, Lighthouse agent and CoreDNS pods, and prints `subctl show all`. The token is passed inline; the remote must not use `brokerK8sSecret`, which would start a secret syncer that its account is not allowed to run.

The equivalent manual command, for reference:

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

`subctl join` is not used here: the broker is Helm-managed and has no `broker-info.subm`, the PSK lives in a secret on the central side, and the identity is the enrolled account.

Expected state on the node a few minutes after the install:

```bash
kubectl -n submariner-operator get pods      # operator, gateway, routeagent, lighthouse-agent, lighthouse-coredns, metrics-proxy all Running
subctl show connections                      # <central-cluster-id> ... libreswan  10.42.0.0/16, <central-service-cidr>  connected
subctl show gateways                         # this node: HA STATUS active, SUMMARY "All connections (1) are established"
subctl diagnose all
kubectl get ippools.projectcalico.org        # two pools created by Submariner for the central CIDRs, disabled: true
```

On the central cluster:

```bash
subctl show connections                      # <cluster-id> ... 10.152.185.0/24, 10.3.0.0/16  connected
kubectl -n submariner-k8s-broker get clusters.submariner.io,endpoints.submariner.io
```

If the gateway log on the node reports the broker refusing an Endpoint or Cluster object, the enrolled CIDRs or the cluster ID differ from what the node advertises; compare `cluster-id.txt` and the `SUBNETS` given at enrollment with `submariner-values.yaml`.

## 6) Verify cross-cluster routing and clusterset DNS

Export a throwaway service from the node and reach it from the central cluster. The cluster-wide deny stops any pod outside the allowed components from reaching remote addresses, so the fetch runs from the federation-z controller pod, which is allowed to dial remote pods on 5672 only; the smoke test therefore checks resolution from a throwaway pod and the TCP path from the controller with the exact port the policy allows.

The broker accepts only the exports in the node's enrollment record. On the central cluster, add the test Service to the record first; the list replaces the recorded one, so keep the worker Service in it:

```bash
kubectl -n submariner-k8s-broker patch configmap cluster-<id> --type merge -p '{"data":{"exports":"federation-z/exareme2-test-workers-service,submariner-smoke/smoke-nginx"}}'
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
  sh -c 'nslookup smoke-nginx.submariner-smoke.svc.clusterset.local'                     # A record inside 10.152.185.0/24
kubectl -n submariner-smoke run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -sS --max-time 5 http://smoke-nginx.submariner-smoke.svc.clusterset.local:8080 || echo denied'   # denied: the global policy blocks it
kubectl -n federation-z exec deploy/exaflow-controller-deployment -- \
  python -c 'import socket,sys; s=socket.create_connection((sys.argv[1],5672),5); print("tcp 5672 open")' <remote worker pod IP>   # after step 8
```

Expected: the name resolves, the fetch from an arbitrary namespace is denied, and the controller reaches the remote worker on 5672 once the worker runs. Clean up on both sides, the node first, then put the record back:

```bash
kubectl delete -f ~/remote-node/smoke-test.yaml           # node
kubectl delete namespace submariner-smoke                 # central
kubectl -n submariner-k8s-broker patch configmap cluster-<id> --type merge -p '{"data":{"exports":"federation-z/exareme2-test-workers-service"}}'   # central
```

## 7) Clean up credentials

On the node, once the connection is established:

```bash
shred -u ~/subm-creds/broker-token.txt ~/subm-creds/broker-ca-base64.txt ~/subm-creds/broker-psk.txt ~/subm-creds/local-values.yaml
```

On the central cluster, remove the enrollment output directory the same way once the files are on the node. The Helm release secret and the `Submariner` resource in `submariner-operator` keep the credentials in the remote cluster; this is inherent to the Helm method. With RBAC (step 4) only the cluster administrator and the Submariner service accounts whose upstream roles cover them (operator, gateway, Lighthouse CoreDNS) can read them. The token expires at the recorded time; re-run the enrollment with the same `CLUSTER_ID` and the join before then.

## 8) Deploy the exaflow worker

The central controller lists `exareme2-test-workers-service.federation-z.svc.clusterset.local` in `controller.workers_dns` (`../mip-infrastructure/customizations/exareme2-values.yaml`) and exports its aggregation server and controller services (`../mip-infrastructure/submariner-policies/service-exports.yaml`). Those changes must be merged and synced before the worker is useful.

The controller resolves every name in that list on each `/healthcheck` call and fails the whole call when one name does not resolve (see `upstream-contributions/exaflow-worker-discovery/`). From the moment the clusterset name is configured until the remote worker is exported and ready, the central controller therefore restarts on its startup probe; `kubectl -n federation-z get pods -l app=exaflow-controller` shows `0/1` with a growing restart count and the log ends with `NXDOMAIN` for the clusterset name. This is expected. Deploy the worker; the controller passes its probe on the first attempt after the worker's endpoint is ready. The same applies whenever the remote worker later disappears: the central controller loses all workers until the name resolves again.

```bash
cd ~/remote-node
./deploy-worker.sh                       # first node: dataset synthetic_a
DATASET=synthetic_b ./deploy-worker.sh   # second node
```

The script applies the namespace `federation-z`, builds the ConfigMap `synthetic-data` from `exaflow-worker/data/synthetic_v_0_1/` (`CDEsMetadata.json` and the CSV named by `DATASET`), renders `exaflow-worker/` with kustomize, substitutes the worker identifier (the enrolled cluster ID), applies the headless Service, the ServiceExport and the worker StatefulSet, waits for the central imports to appear in the namespace and then for the worker to become ready. Readiness requires the data model to load from the ConfigMap, mounted at `/opt/csvs/synthetic_v_0_1`. The worker reads it only at start-up, so the script restarts an existing worker when the ConfigMap changed. Every node serves a different CSV and all nodes share the same metadata file; see Adding a second remote node.

`exaflow-worker/networkpolicy.yaml` limits the worker to the central cluster. In: only the central pod CIDR, on the gRPC port 5672. Out: DNS and the central aggregation server (50051) at its ClusterIP in the central service CIDR. If a tunnel to another remote node forms anyway, that node's pods cannot reach the worker, and the worker cannot send data anywhere else.

The worker pod mounts no service-account token (`automountServiceAccountToken: false` in `exaflow-worker/statefulset.yaml`). The worker never calls the Kubernetes API, and the analysis code it runs gets no credential for the node's cluster. Applying this setting to a running worker restarts it once.

Verify on the central cluster:

```bash
kubectl -n federation-z get serviceimport                                   # exareme2-test-workers-service appears
kubectl -n federation-z run curl --rm -it --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c 'curl -sS http://exaflow-controller-service:5000/healthcheck && curl -sS http://exaflow-controller-service:5000/datasets_locations'
```

`datasets_locations` lists each dataset under the cluster ID of the node serving it (`synthetic_a` for the first node). A descriptive-statistics run against `synthetic_a` from the MIP frontend or the controller API completes the end-to-end check; an xgboost run additionally exercises the Flower path (remote worker to controller 5000 and to the global worker 8080).

To serve real data, replace the `csv-data` ConfigMap volume in `exaflow-worker/statefulset.yaml` with a hostPath or PersistentVolumeClaim holding one directory per data model, mounted at `/opt/csvs`, and re-run `deploy-worker.sh` (the ConfigMap it builds is then unused).

## Operations

- Re-running any script is safe; each step checks the current state first.
- Health: `./preflight.sh --stage health` on the node checks the node's side: the connection to the central cluster and the address it runs through (the central gateway's LoadBalancer address), the gateway policy routing for every remote CIDR, the networkd drop-in, the route watchdog, the IPsec firewall, the API server's authorization (RBAC, checked on the running server: an identity without a role must be refused), the kubelet's authorization (a token without a role must get 403 on port 10250), the kube-controller-manager's right to read Calico tiers, the worker's export (published to the broker, `Ready=True`), clusterset DNS from the worker and a TCP connection from the worker to the aggregation server. DNS alone does not show a publishing failure: imports and DNS answer from local copies, so the node still resolves every name while the central cluster uses stale data. A name can also resolve to an address that no longer answers, when the central side publishes a stale record; the connection test detects that. `../enrollment/check-central.sh` checks the central side. Run both after a reboot, an upgrade or a change on the central cluster. Each gateway reports only its own side, so one can show `connected` and the other `error`.
- Credential rotation: re-run `enroll-remote.sh CLUSTER_ID=<id> ...` on the central cluster with the `SUBNETS` and `EXPORTS` of the first enrollment, transfer the new files and re-run `join-submariner.sh`; Helm upgrades the release in place. `ROTATE_IDENTITY=true` additionally invalidates all earlier tokens of the account.
- Allowed exports: the node may publish only the services in its enrollment record, the `exports` entry of the ConfigMap `cluster-<id>` in `submariner-k8s-broker` on the central cluster. To add or remove one, patch the record there as in step 6 and run `../enrollment/verify-enrollment.sh CLUSTER_ID=<id> IMPERSONATE=true`, which needs no token. Delete a ServiceExport on the node before its entry is removed from the record.
- Version alignment: the Submariner version is pinned in `common/submariner/operator/kustomization.yaml` (central) and as `SUBMARINER_VERSION` in `setup-tools.sh`, `preflight.sh` and `join-submariner.sh` (remote). Renovate moves them together (group `submariner`).
- Upgrading Submariner: plan central and all nodes as one maintenance window.
  1. Apply any change to the out-of-band RBAC.
  2. Let Argo CD sync the central chart. The operator restarts, updates the CRDs and rolls the gateway, route agent and Lighthouse.
  3. On every node, take a VM snapshot, copy the updated directory and run, with the node's own `VALUES_FILE` and `DATASET` where it has them (node 2: `submariner-values-node2.yaml`, `synthetic_b`):
     - `sudo ./setup-tools.sh`: installs the matching `subctl`.
     - `./join-submariner.sh`, from a directory without credential files: upgrades the existing release in place with its stored credentials and waits until every pod runs the target version.
     - `./deploy-worker.sh`: re-applies the worker's export and, if changed, the worker image.
     - `./preflight.sh --stage health`.
  4. Verify with `subctl show versions` and `subctl show connections` on the node and on the central cluster.

  The Lighthouse agent and CoreDNS can restart once when they start before the operator has updated the local MCS CRDs (`error getting REST mapper` for `v1beta1`). The central controller can restart once while a node's tunnel is down (see step 8). Across a libreswan major version (0.21 to 0.24: libreswan 4 to 5) the two ends reject each other's child-SA proposals, and the tunnels stay `connecting` until the node runs the new version. 0.24 and 0.25 both use libreswan 5 and the MCS API serves both versions, so a node on 0.24 keeps working until its upgrade.
- After the central side is upgraded, run `../enrollment/check-central.sh` before touching the nodes and again at the end. One of its checks is the `clusterset.local` forward in the cluster CoreDNS Corefile: a re-apply of the CoreDNS chart drops it, and every clusterset name then returns NXDOMAIN on the central side, controller included. `kubectl -n submariner-operator rollout restart deploy/submariner-operator` makes the operator write it again. Clean up the smoke-test namespaces on both sides before the upgrade, or the leftover export shows up in every agent log.
- MicroK8s follows its snap track (`1.33/stable`) and receives patch releases automatically. Moving to another track is a reinstall (`reset-node.sh`, new channel).
- The Calico API server certificate expires after 365 days. Delete the `calico-apiserver-certs` secret in `calico-apiserver` and re-run `setup-microk8s.sh` to renew it.
- MicroK8s certificates: the automatic re-issue on address change is disabled, expiry is not. `sudo microk8s refresh-certs -c` shows the remaining validity (365 days for the server and front-proxy certificates). Renew with `sudo microk8s refresh-certs -e server.crt` and `-e front-proxy-client.crt` in a maintenance window: the control plane restarts, and the Lighthouse agent pod must be recreated afterwards if its log shows the probe error described under Troubleshooting.

## Adding a second remote node

Every node has its own CIDRs, cluster ID, values file and dataset; the scripts are shared. The second node of federation-Z uses `10.4.0.0/16`, `10.152.186.0/24`, `submariner-values-node2.yaml` and the dataset `synthetic_b`; a further node needs the same four additions.

1. Repository first: the node's pod CIDR is an `ipBlock` in every rule of `../mip-infrastructure/submariner-policies/network-policy.yaml`, its pod and service CIDRs are an entry of `../mip-infrastructure/remote-networks.yaml`, a copy of `submariner-values.yaml` with the node's CIDRs exists next to it (`submariner-values-<node>.yaml`), and `exaflow-worker/data/synthetic_v_0_1/` holds the node's CSV with its dataset code listed in `CDEsMetadata.json`. `scripts/check-remote-cidrs.sh` asserts that the CIDRs agree. Merge, and let Argo CD sync `netpol-federation-z-remote` and the federation's `submariner-network-policy` before the join.
2. Enroll with the node's CIDRs and its own output directory:

   ```bash
   cd deployments/hybrid/federations/federation-Z/enrollment
   ./enroll-remote.sh SUBNETS=10.4.0.0/16,10.152.186.0/24 OUT_DIR=~/subm-creds-node2 BROKER_URL=https://<broker-api-host>:6443
   ./verify-enrollment.sh OUT_DIR=~/subm-creds-node2
   ```

   The node gets its own cluster ID; record it with the site and the token expiry.
3. Copy `remote-node/` and the credential files to the node as in steps 1 to 3, then run the node steps with the node's CIDRs:

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

   The join refuses a values file whose CIDRs differ from the live cluster. A node behind NAT needs nothing else: `natEnabled` is already set, the tunnel is initiated from the node and the gateway discovers its public address (see Troubleshooting if the connection stays in `connecting`).
4. Steps 6 and 7 as for the first node.
5. Step 8 with the node's dataset: `DATASET=synthetic_b ./deploy-worker.sh`. The controller drops a dataset code that two workers serve, so every node serves a different CSV. The controller merges the dataset enumerations of one data model across workers, but it also keeps every distinct metadata version it receives (`data_models_attributes`, property `cdes`), and the platform backend builds the variable tree the UI shows from the first entry only: with two versions in play the UI lists the datasets of whichever node registered first (observed on 2026-09-29: `synthetic_b` absent from the UI while every controller endpoint listed it). All nodes must therefore carry the byte-identical `CDEsMetadata.json`. When that file changes, re-run `deploy-worker.sh` on every existing node right away: the script restarts their workers, and while a worker restarts the central controller loses the remote workers as described in step 8 unless another remote worker is ready. `controller.workers_dns` on the central side does not change: all nodes export the same headless Service name, and the clusterset name resolves to every ready remote worker pod.
6. The remote gateways also try tunnels to each other, because Submariner forms a full mesh. Between a node with a public address and a node behind NAT such a tunnel can come up. The IPsec firewall (step 4 and the hardening playbook) blocks it, and the worker's NetworkPolicy (step 8) admits only the central networks. The gateways still log these attempts; Submariner has no hub-and-spoke option yet (proposal: `upstream-contributions/submariner-hub-and-spoke/`). Only the connections to the central cluster matter for the federation.

## Removing a remote node

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

`subctl uninstall --yes` performs the same removal in one step. For a full reset of the node use `reset-node.sh`.

On the central cluster, with the node's cluster ID:

```bash
deployments/hybrid/federations/federation-Z/enrollment/revoke-remote.sh CLUSTER_ID=<cluster-id>
subctl show connections            # the node no longer appears
```

`revoke-remote.sh` deletes the account (invalidating its tokens), its bindings and ConfigMap, and the node's `Cluster`, `Endpoint`, `EndpointSlice` and ServiceImport entries on the broker. For a node that predates enrollment, delete the broker objects by hand:

```bash
ID=<cluster-id>
kubectl -n submariner-k8s-broker delete clusters.submariner.io "$ID" --ignore-not-found
kubectl -n submariner-k8s-broker delete endpoints.submariner.io -l submariner-io/clusterID="$ID"
kubectl -n submariner-k8s-broker delete serviceimports.multicluster.x-k8s.io,endpointslices -l submariner-io/clusterID="$ID"
```

Then remove the node's CIDRs from the two policy files.

## Troubleshooting

### Certificate errors ("x509: certificate signed by unknown authority")

The broker CA was not passed correctly: `broker.ca` must be a base64 string, not PEM. Verify from the node:

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

### The broker refuses the node's objects ("denied request" from a ValidatingAdmissionPolicy)

The node advertises a cluster ID or subnets that differ from its enrollment. `cluster-id.txt` must equal the suffix of the account the token belongs to (`preflight.sh --stage join` checks the token subject), and `submariner.clusterCidr` and `serviceCidr` in `submariner-values.yaml` must lie within the `SUBNETS` given to `enroll-remote.sh`. Re-enroll with the right values or fix the values file, then re-run the join.

A refusal by `submariner-remote-cluster-exports` means the node publishes a service that is not in its enrollment record. The ServiceExport on the node does not become `Ready`, and its status and the Lighthouse agent log carry the broker's message, which names the service and the recorded exports. Add the service to the record on the central cluster (the command is in step 6) or delete the ServiceExport on the node. A message about parameters that were not found means that no enrollment record exists on the central cluster.

### Tunnel never leaves `connecting`

- IKE fails on both sides with authentication errors: the PSK differs. The remote must use `.data.psk` as stored (not decoded). Compare `sha256sum broker-psk.txt` with `kubectl -n submariner-operator get secret submariner-ipsec-psk -o jsonpath='{.data.psk}' | sha256sum` on the central cluster.
- No IKE answer: UDP 4500 (or 4490 for NAT discovery) to `<gateway-public-ip>` is blocked, or the public IP the gateway discovered is wrong. Check `kubectl -n submariner-operator logs ds/submariner-gateway`; override the public IP with `kubectl annotate node <node> gateway.submariner.io/public-ip=ipv4:<ip>`.
- Central side shows the connection but the remote does not: the central gateway `externalTrafficPolicy: Local` service only answers on the node hosting the gateway pod; check `subctl show gateways` on the central cluster.
- The node accepts IPsec only from `CENTRAL_GATEWAY_IP` (step 4). If the central LoadBalancer address changed, or the gateway Service does not serve UDP 4500 and 4490 (`../enrollment/check-central.sh` checks both), the tunnel stays in `connecting`. `./preflight.sh --stage health` shows the address the tunnel uses; after correcting `central.env`, re-run `setup-microk8s.sh`, which reloads the table and recreates the gateway pod.

### Connection shows `error` while the IPsec SAs are established

- `subctl show connections` reports `error` with `Failed to successfully ping the remote endpoint IP`, `ipsec status` in the gateway pod shows established child SAs, and on the node `ip route show table 150` is empty; depending on the cause, `ip rule show` has lost its `lookup 150` entry as well. The route agent installs that rule and the table-150 routes (remote CIDRs, source = the node's Calico address) on the gateway node so that host-originated packets, the gateway's health check included, match the IPsec policies; without them the pings leave with the public address and are dropped while pod traffic still flows. Lighthouse stops answering for a cluster whose connection is not `connected`, so the worker gets NXDOMAIN for the central names and the central controller restarts (step 8). `ping -I <calico address> <remote health-check address>` succeeding while a plain ping fails confirms the diagnosis.
- Cause seen on 2026-09-30 on every Ubuntu host of the federation: unattended-upgrades installed an openssl update, needrestart restarted `systemd-networkd`, and networkd removed the rule and routes as foreign (defaults `ManageForeignRoutes=yes`, `ManageForeignRoutingPolicyRules=yes`). `journalctl -u systemd-networkd --since today` and `/var/log/apt/history.log` show the moment. The route agent only programs them at gateway transition and endpoint events.
- Second cause, not prevented by the drop-in: with a DHCP uplink, systemd-networkd removes the interface address and adds it again when it restarts (for example after an unattended upgrade). The kernel drops every route through an interface that loses its last address, so table 150 is emptied while the rule stays. No `KeepConfiguration=` value avoids this on Ubuntu 24.04 (systemd 255.4); `dhcp-on-stop`, `dhcp` and `yes` do not.
- Recovery is automatic: the route watchdog installed by `setup-microk8s.sh` sees the missing routes in two checks one minute apart and restarts the route agent. The connection is `connected` again about two minutes after the networkd restart. `sudo journalctl -u submariner-route-watchdog` lists every loss. By hand: `kubectl -n submariner-operator delete pod -l app=submariner-routeagent`; the new pod re-installs the rule and routes and the connection is `connected` within seconds.
- Prevention of the first cause: the drop-in written by `setup-microk8s.sh` and by the hardening post-run block. `./preflight.sh --stage health` checks the drop-in and the watchdog. On the central cluster the DaemonSets `submariner-gateway-node-config` and `submariner-gateway-route-watchdog` do the same on the gateway node (`common/submariner/README.md`, "Gateway node").

### The node keeps an old central endpoint after the central gateway moved

- When the central gateway moves to another node, the broker gets a new central Endpoint (new host name and private address). The node does not always pick it up. If it keeps the old one, its connection to the central cluster stays `connecting` or `error`, and the central gateway logs `Received NAT discovery packet for endpoint "...-<old address>-v4", but we are endpoint "...-<new address>-v4"`.
- Check: `./preflight.sh --stage health` prints the central endpoint the node holds. Compare it with `kubectl -n submariner-k8s-broker get endpoints.submariner.io` on the central cluster.
- Recovery: `kubectl -n submariner-operator delete pod -l app=submariner-gateway`. The new gateway pod syncs again with the broker.

### `clusterset.local` names do not resolve

- Imports are distributed into the namespace of the exported service and only once that namespace exists locally. Right after the join the node has no `federation-z` namespace, so `kubectl get serviceimports -A` is empty, the central names do not resolve yet, and the agent logs `Unable to distribute resource ... due to missing namespace "federation-z"`. This is expected; the agent retries when the namespace appears (step 8 creates it), and `kubectl -n federation-z get serviceimports` then lists the central exports.
- On the node, `kubectl -n kube-system get configmap coredns -o yaml` must contain a `clusterset.local` block forwarding to the Lighthouse CoreDNS service. Re-enabling the MicroK8s `dns` addon rewrites the ConfigMap and drops the block; the operator re-adds it after a restart of `submariner-operator`.
- Repeated `x509: certificate signed by unknown authority` in `kubectl -n submariner-operator logs deploy/submariner-lighthouse-agent`: the broker CA given at the join is wrong; see "Certificate errors" above. Exception on 0.24 or older: if cluster DNS was unavailable when the agent started (reboot, control-plane restart), the agent keeps a client without the CA, while the gateway, which uses the same CA, shows no x509 errors. Recreate the agent pod (`kubectl -n submariner-operator delete pod -l app=submariner-lighthouse-agent`) and confirm the export with `./preflight.sh --stage health`. 0.25 always loads the CA.
- The files in this directory target 0.25. On a 0.24 node, `deploy-worker.sh` stops at the `v1beta1` ServiceExport, which the 0.24 CRDs do not serve; run it only after the node's upgrade.
- `kubectl get serviceexport -A -o yaml` must show `Valid=True` and `Ready=True`; a `False` condition carries a message naming the cause (typically the Service does not exist yet).
- On the central cluster, the ServiceImport appears in the exporting namespace; if it does not, check `kubectl -n submariner-operator logs deploy/submariner-lighthouse-agent` on both sides.

### The node came back under another name (snapshot restore, instance rename)

`kubectl get nodes` shows two nodes with the same address: the original one `NotReady` and still labelled `submariner.io/gateway=true`, a new one named after the instance with `calico-node` in `CrashLoopBackOff` ("is already using the IPv4 address"). The gateway, the route agent and the worker pods are bound to the dead node object, `subctl show connections` repeats its last state, and the tunnel is down. Cause: cloud-init set the host name from the instance name at boot. Restore the name, pin it, and let the kubelet re-register:

```bash
sudo hostnamectl set-hostname <original node name>
sudo sed -i 's/<new instance name>/<original node name>/g' /etc/hosts
printf 'preserve_hostname: true\n' | sudo tee /etc/cloud/cloud.cfg.d/99-microk8s-preserve-hostname.cfg
sudo microk8s stop && sudo microk8s start
kubectl delete node <new instance name>
kubectl get nodes; kubectl -n submariner-operator get pods; subctl show connections
```

The original node object turns `Ready`, the orphaned pods are recreated, the gateway re-establishes the tunnel and the worker reloads its data. Renaming the instance back in the provider console is the alternative when the name must stay in sync with the console.

### Calico reports the node address on `vx-submariner`

`kubectl get node -o jsonpath='{.items[0].metadata.annotations.projectcalico\.org/IPv4Address}'` returns an address in `240.0.0.0/8` and the calico-node log says `IPv4 address has changed`. Calico's default autodetection (`first-found`) enumerates interfaces newest first, so the Submariner tunnel interface wins after the join. Re-run `setup-microk8s.sh`, or apply the same settings by hand:

```bash
kubectl -n kube-system set env ds/calico-node IP_AUTODETECTION_METHOD=kubernetes-internal-ip
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
sudo sed -i '/name: IP_AUTODETECTION_METHOD/{n;s|value: ".*"|value: "kubernetes-internal-ip"|}' /var/snap/microk8s/current/args/cni-network/cni.yaml
sudo touch /var/snap/microk8s/current/var/lock/no-cert-reissue
```

The last command stops MicroK8s from re-issuing its certificates and restarting the control plane whenever a host address appears or disappears, which happens at every join and reboot with the tunnel interface. Without it the Submariner pods restart during the join and the Lighthouse agent hits the probe failure described above.

### A flow is denied on the central side

The Calico policy `remote-clusters.federation-z` denies everything from the federation's remote CIDRs except the four allowed flows towards the namespace `federation-z`, and the namespaced policies in `federation-z` allow only those ports from the listed `ipBlock`s. Check that the node's CIDRs are an entry of `../mip-infrastructure/remote-networks.yaml` and that its pod CIDR is in the namespaced policies; `../enrollment/check-central.sh` compares the two on the cluster. On the central node hosting the destination pod, `iptables-save -c | grep remote-clusters.federation-z` shows the deny counters.

### `preflight.sh` fails on "API authorization" or "kubelet authorization"

- "API authorization" fails when the API server allows every authenticated request: the node was set up without RBAC, or the argument was set back. `sudo grep authorization-mode /var/snap/microk8s/current/args/kube-apiserver` shows `AlwaysAllow` and `microk8s status` lists `rbac` as disabled. Any pod can then read the broker token and the IPsec PSK with its service-account token.
- "kubelet authorization" fails when the kubelet allows every authenticated request on its port 10250: `sudo grep authorization-mode /var/snap/microk8s/current/args/kubelet` shows nothing or `AlwaysAllow`. Any service-account token that reaches the port can then run commands in every pod, even with RBAC on the API server.
- Fix: take a VM snapshot and re-run `sudo ./setup-microk8s.sh` with the node's CIDRs. It sets the kubelet's `Webhook` mode and enables RBAC with `microk8s enable rbac`; one restart of the control plane applies both. The API does not answer for about a minute; the pods, the tunnel and cluster DNS keep running. Pods that hold a leader lease, such as the Submariner operator and `calico-kube-controllers`, can restart once. The kubelet probes every pod again after its restart, so the worker is reported not ready for up to a minute and the central controller can lose it for that time. Then run `./preflight.sh --stage health` on the node and `../enrollment/check-central.sh` on the central cluster.
- If a check fails although the files show `RBAC,Node` and `Webhook`, the running control plane predates the change: `sudo snap restart microk8s.daemon-kubelite`.
- The script stops before the change when the kubelet certificate names another host than the registered node (`the kubelet authenticates as ...`). With RBAC the kubelet reads the Secrets and ConfigMaps of its pods only under the name in its certificate. Restore the host name first (see "The node came back under another name"). It also stops when the API server's client certificate for the kubelet is not in `system:masters`, because `kubectl logs` and `kubectl exec` would then be refused.
- Do not use `microk8s disable rbac`: it sets `AlwaysAllow` again and deletes the default roles of Kubernetes.
- The credentials were readable by every pod while the mode was `AlwaysAllow`. If a workload that is not trusted ran on the node in that time, rotate the node's token afterwards (Operations, credential rotation, with `ROTATE_IDENTITY=true`).

### A component logs `forbidden` after RBAC was enabled

- With RBAC a service account holds only what its roles grant. The message names the account, the verb and the resource: `... is forbidden: User "system:serviceaccount:submariner-operator:<account>" cannot <verb> resource "<resource>" ...`. A message that names an account `cluster-<id>` of `submariner-k8s-broker` comes from the central broker, not from this node: the node's account may not list Secrets there, by design, and the gateway logs that refusal repeatedly.
- List what an account may do: `kubectl auth can-i --list --as=system:serviceaccount:submariner-operator:<account> --namespace submariner-operator`. The answer is meaningful only while RBAC is on.
- The Calico API server logs `Operation on Calico tiered policy is forbidden: User "system:kube-controller-manager" cannot list ... (user cannot get tier)`, and `journalctl -u snap.microk8s.daemon-kubelite` shows `timed out waiting for dependency graph builder sync during GC sync`: the role `calico-tier-getter` is missing. `preflight.sh` reports it as "controller manager reads Calico tiers". Re-run `setup-microk8s.sh`; it applies the role without a restart.
- In the first seconds after RBAC is enabled, the Calico API server and `calico-kube-controllers` log refusals that name `system:auth-delegator` or `/healthz`. Kubernetes creates its default roles at that moment, and the messages stop by themselves.
- The Submariner roles and bindings come from the chart and equal those of the upstream operator: `kubectl get clusterrole,clusterrolebinding | grep submariner` and `kubectl -n submariner-operator get role,rolebinding`. If one was deleted, `./join-submariner.sh` from a directory without credential files re-applies the chart. The Calico API server's roles come from its manifest, which `setup-microk8s.sh` re-applies together with `calico-tier-getter`; the roles of `calico-node` and CoreDNS come with MicroK8s.
- A client that calls the kubelet directly on port 10250, such as a metrics scraper, needs a role on the `nodes` subresources it reads (`nodes/metrics`, `nodes/stats`, `nodes/proxy`); the kubelet answers 403 otherwise. Nothing in this runbook calls it directly.

### Route agent cannot create IP pools

`kubectl -n submariner-operator logs ds/submariner-routeagent` reports `ippools.projectcalico.org` errors when the Calico API server is not available. Check `kubectl get apiservice v3.projectcalico.org` and `kubectl -n calico-apiserver get pods`; re-run `setup-microk8s.sh`.

### subctl reports a version mismatch

`subctl` must match the deployed Submariner version. Re-run `setup-tools.sh` with the right `SUBMARINER_VERSION`.

### Central controller discovers no workers

The controller resolves every name in `controller.workers_dns` in one pass; one unresolvable name aborts discovery of all workers, including the central ones, until the next update cycle. Check `kubectl -n federation-z logs deploy/exaflow-controller-deployment | grep -i -E 'NXDOMAIN|WorkerLandscapeAggregator'` and confirm the remote ServiceExport is synced before the controller is expected to be healthy.

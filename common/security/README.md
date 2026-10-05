# MIP Security Network Policies

This module implements network isolation policies for MIP federations and common namespaces to ensure secure, isolated communication between different components of the MIP infrastructure.

## Overview

The security policies implement a **zero-trust network model** where:
- Each federation namespace is isolated and can only communicate within itself
- Common namespaces are accessible by federation namespaces for shared services
- DNS access to `kube-system` is maintained for cluster functionality
- ArgoCD management access is preserved
- External HTTP/HTTPS access is allowed for container registries and APIs

## Architecture

![Network Policy Architecture](diagram.svg)

The diagram above shows the network isolation architecture with:

- **Federation Namespaces**: Auto-discovered and isolated from each other
- **Common Services**: Shared resources with controlled access 
- **Access Control Switches**: Type-based configuration for federation access
- **System Services**: Always accessible for DNS and external connectivity
- **Security Boundaries**: Default-deny with explicit allow rules

## Network Policy Rules

### Federation Namespaces (`federation-*`)

**Ingress (Allowed)**:
- Traffic from the same namespace
- Traffic from ArgoCD namespace (`argocd-mip-team`)

**Egress (Allowed)**:
- Traffic to the same namespace
- DNS queries to `kube-system` (UDP/TCP port 53)
- External HTTP (port 80) and HTTPS (port 443)

### Common Namespaces (`mip-common-*`)

**Ingress (Allowed)**:
- Traffic from the same namespace
- Traffic from federation namespaces (**controlled by access switches**, see Configuration)
- Traffic from ArgoCD namespace

**Egress (Allowed)**:
- Traffic to the same namespace
- DNS queries to `kube-system` (UDP/TCP port 53)
- External HTTP (port 80) and HTTPS (port 443)

## Configuration

The network policies use **auto-discovery** for federation namespaces and static configuration for common namespaces:

### **Auto-Discovery for Federation Namespaces**

Federation namespaces are **automatically discovered** from git repositories:
- **Local federations**: `deployments/local/federations/*`
- **Hybrid federations**: `deployments/hybrid/federations/*/mip-infrastructure`

### **Static Configuration for Common Namespaces**

Common namespaces are configured via the `common-network-policies` ApplicationSet in `netpol.yaml`:

```yaml
generators:
  - list:
      elements:
        - commonNamespace: mip-common-datacatalog
        - commonNamespace: mip-athena            # Jupyter AI proxy
        - commonNamespace: mip-notebooks-system  # notebook operator
```

Each gets the namespace isolation and default-deny policies of
`common-templates`, plus a namespace-specific block in the same template:
`mip-athena` admits only federation notebook pods and lets only `athena-proxy`
reach the inference server (`athenaProxy.upstream` in `common-templates/values.yaml`);
`mip-notebooks-system` lets the operator and the `mip-notebook-rbac-manager` CronJob reach the API server on 6443.

### API server egress (`apiServer.cidrs`)

The JupyterHub pod of every federation, the notebook operator and its RBAC reconciler in
`mip-notebooks-system` talk to the Kubernetes API. NetworkPolicy is evaluated after the
`kubernetes` Service DNAT, so the egress rules on TCP 6443 see the control-plane node
addresses, not the Service address. `apiServer.cidrs` in `federation/values.yaml` and
`common-templates/values.yaml` limits those rules to the listed addresses; an empty list admits
any address on 6443. Both files must carry the same list (the e2e render job compares them).
Read the addresses from the cluster, and update the list when control-plane nodes change:

```bash
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes \
  -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}/32{"\n"}{end}'
```

`deployments/hybrid/federations/federation-Z/enrollment/check-central.sh` compares the list
with the live endpoints on every run and fails when an endpoint is not covered.

The JupyterHub pod may always reach the notebook API proxy in `mip-notebooks-system` on 8443
(`common/notebook-operator/manifests/api-proxy.yaml`). `apiServer.hubDirect` in
`federation/values.yaml` additionally keeps the pinned 6443 rule; set it to `false` once every
hub talks through the proxy. The policy keeps its name in both states so Argo CD updates it in
place. The `mip-notebooks-system` block admits the hub pods of federation namespaces to the
proxy, lets the proxy reach the API server, and gives that namespace no external HTTP or HTTPS
egress at all (`networkPolicy.noExternalEgress`). The switch and the step after it are described
in [`how-to-implement-the-notebook-properly.md`](../../how-to-implement-the-notebook-properly.md).

Federation access control for those namespaces is configured via `common-templates/values.yaml`:

```yaml
# Federation access control (by TYPE, not specific namespaces)
federationAccess:
  local:
    enabled: false  # Default: false (more secure)
    allowedCommonNamespaces:
      # - mip-common-datacatalog
  hybrid:
    enabled: false  # Default: false (more secure)
    allowedCommonNamespaces:
      # - mip-common-datacatalog
```

### Federation Access Control

**Important**: Access control is **type-based** rather than namespace-specific:

- **Local federations** (`mip.federation-type: local`) have separate access controls
- **Hybrid federations** (`mip.federation-type: hybrid`) have separate access controls  
- By default, **all federation types cannot** access common namespaces (`enabled: false`)

To enable access:

1. **Enable by type**: Set `federationAccess.local.enabled: true` for all local federations
2. **Configure allowed namespaces**: List which common namespaces that federation type can access
3. **Apply changes**: Commit and push - ArgoCD will update the policies automatically

**Security Note**: The `mip-common-security` namespace should typically **not** be accessible by any federation type.

### Adding New Namespaces

#### **Federation Namespace (Auto-Discovery)**
Simply add the federation directory to the git repository:
- **Local federation**: Create `deployments/local/federations/federation-new/`  
- **Hybrid federation**: Create `deployments/hybrid/federations/federation-new/mip-infrastructure/`

The ApplicationSet will **automatically discover and apply** network policies!

#### **Common Namespace (Manual Configuration)**
1. Add the namespace to the `common-network-policies` ApplicationSet list in `common/security/netpol.yaml`
2. Optionally add it to federation access lists in `common-templates/values.yaml`
3. Commit and push - ArgoCD will automatically apply the policies

**Example: Enable local federations to access datacatalog**:
```yaml
federationAccess:
  local:
    enabled: true     # Enable ALL local federations
    allowedCommonNamespaces:
      - mip-common-datacatalog  # Allow access to datacatalog only
```

### Customizing Policies

You can customize the network policies by modifying:

- `netpol.yaml` - Common namespace app generation
- `values.yaml` - Federation access and global settings
- `federation/templates/federation-network-policy.yaml` - Federation-specific rules
- `common-templates/templates/common-network-policies.yaml` - Common namespaces, with one block per namespace that needs more than isolation
- `templates/common-network-policies.yaml` - Common namespace rules

## Deployment

The security policies are automatically deployed by the main `mip-infrastructure` ApplicationSet when it discovers the `common/security` directory.

### How It Works

1. **Security AppProject**: `mip-argo-project-security` provides dedicated permissions for network policy management
2. **Federation Policies**: `federation-network-policies` ApplicationSet auto-discovers federations and creates individual network policy applications for each
3. **Common Policies**: `common-network-policies` ApplicationSet deploys policies to all common namespaces

### Manual Deployment

If needed, you can deploy manually:

```bash
# Deploy the ApplicationSets
kubectl apply -f common/security/netpol.yaml

# Sync the applications (security project must exist first)
argocd app sync mip-argo-project-security-app
argocd app sync federation-network-policies  
argocd app sync common-network-policies

# Check auto-generated applications
argocd app list | grep netpol-
```

## Troubleshooting

### Network Connectivity Issues

If applications cannot connect after applying policies:

1. **Check policy application**:
   ```bash
   kubectl get networkpolicies -n <namespace>
   ```

2. **Verify namespace labels**:
   ```bash
   kubectl get namespace <namespace> --show-labels
   ```
   
   Ensure namespaces have the `name` label matching their namespace name.

3. **Test DNS resolution**:
   ```bash
   kubectl run test-dns --image=busybox --rm -it -- nslookup kubernetes.default
   ```

4. **Check ArgoCD access**:
   ```bash
   kubectl get pods -n argocd-mip-team
   ```

### Common Issues

- **DNS not working**: Ensure `kube-system` namespace has proper labels
- **ArgoCD can't sync**: Check ArgoCD namespace access rules
- **External dependencies failing**: Verify HTTP/HTTPS egress rules

## Security Considerations

- **Default Deny**: All traffic is denied by default unless explicitly allowed
- **Principle of Least Privilege**: Only necessary communication is permitted
- **Federation Isolation**: Federations cannot communicate with each other
- **Granular Common Access**: Federation access to common services is **disabled by default** and must be explicitly enabled
- **Federation Type Separation**: Local and hybrid federations have separate access controls
- **Management Access**: ArgoCD retains full management capabilities

## Remote clusters (Submariner)

Hybrid federations receive the same default deny as local ones (the
`federation-network-policies` ApplicationSet discovers
`deployments/hybrid/federations/*/mip-infrastructure`). The flows a
federation needs from its remote nodes are allowed per component and port in
the federation's own `submariner-policies/` directory, with one `ipBlock` per
remote pod CIDR.

`remote-clusters/` adds a cluster-wide safety net: a Calico `Tier`
(`remote-clusters`, order 500) and a `GlobalNetworkPolicy` that deny any
traffic from or to the remote CIDRs outside the exaflow controller, aggregation
server and Flower server of hybrid federations, and pass everything else on to
the Kubernetes NetworkPolicies. It is synced by the `netpol-remote-clusters`
Application (project `mip-argo-project-security`, which whitelists `Tier` and
`GlobalNetworkPolicy`; the application controller ClusterRole grants the
matching verbs). Calico 3.29 or later is required for tiers
(`kubectl get tiers.projectcalico.org` must list `default`).

When a remote node is added, its pod CIDR goes into the federation's
`submariner-policies/network-policy.yaml` and its pod and service CIDRs into
`remote-clusters/global-deny-remote-cidrs.yaml`;
`scripts/check-remote-cidrs.sh` (run in CI) asserts that the three places agree
with the node's `submariner-values.yaml`.

The worker isolation policies of the federation chart
(`federation/templates/exareme-network-policy.yaml`) still select the
pre-1.0.0 labels `app: exareme2-*` and match no pod. Re-enabling them requires
the corrected selectors and complete rules (controller to worker 5672, worker
to aggregation server 50051, worker to controller 5000, worker DNS, local
worker to global worker 8080) together with the `excludedSelector` parameter
in `netpol.yaml`; that change alters local federations too and is tracked
separately.

## Monitoring

Monitor network policy effectiveness:

```bash
# Check denied connections (if using Falco or similar)
kubectl logs -n kube-system <falco-pod>

# View network policy events
kubectl get events --field-selector reason=NetworkPolicyDenied
``` 


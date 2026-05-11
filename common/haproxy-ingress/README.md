# HAProxy public ingress

This folder defines the public HAProxy Kubernetes Ingress Controller used for
externally exposed MIP services.

The top-level Argo CD wrapper is [haproxy-ingress.yaml](haproxy-ingress.yaml).
It points Argo CD at [manifests](manifests), which contains the actual
Kubernetes resources.

RBAC is defined separately in
[base/mip-infrastructure/rbac/haproxy-public-rbac.yaml](../../base/mip-infrastructure/rbac/haproxy-public-rbac.yaml).

## What gets deployed

- An Argo CD `Application` named `haproxy-public-ingress`
- A HAProxy KIC `Deployment` in `ingress-nginx`
- A `LoadBalancer` Service named `haproxy-public-controller`
- An `IngressClass` named `haproxy-public`
- A default certificate, ClusterIssuer, and ConfigMap used by the controller

Current controller settings:
- Image: `haproxytech/kubernetes-ingress:3.2.8`
- Publish service: `ingress-nginx/haproxy-public-controller`
- Ingress class: `haproxy-public`
- IngressClass controller string: `haproxy.org/ingress-controller/haproxy-public`
- MetalLB IP: `x.x.x.x`

## How to use it

1. Apply the RBAC in
   [base/mip-infrastructure/rbac/haproxy-public-rbac.yaml](../../base/mip-infrastructure/rbac/haproxy-public-rbac.yaml).
2. Sync the Argo CD Application from [haproxy-ingress.yaml](haproxy-ingress.yaml).
3. Create an `Ingress` with `spec.ingressClassName: haproxy-public`.
4. If the hostname is public, provision TLS with cert-manager as usual.

Example:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
  namespace: default
spec:
  ingressClassName: haproxy-public
  rules:
    - host: example.mip-tds.chuv.cscs.ch
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: example
                port:
                  number: 80
```

## Verification

```bash
kubectl -n ingress-nginx get deploy haproxy-public-controller
kubectl -n ingress-nginx get svc haproxy-public-controller -o wide
kubectl get ingress -A -o wide | grep haproxy-public
kubectl -n ingress-nginx logs deploy/haproxy-public-controller --tail=100
```

Expected result:
- The Service has external IP `x.x.x.x`.
- `haproxy-public` Ingresses show that IP in their `ADDRESS` column.

## Troubleshooting

- If the Service never gets an external IP, check the MetalLB pool and the
  `metallb.io/address-pool` annotation in
  [manifests/haproxy-public-service.yaml](manifests/haproxy-public-service.yaml).
- If the controller is running but `haproxy-public` Ingresses stay without an
  `ADDRESS`, check controller logs and confirm RBAC still allows `update` and
  `patch` on `ingresses/status` in
  [base/mip-infrastructure/rbac/haproxy-public-rbac.yaml](../../base/mip-infrastructure/rbac/haproxy-public-rbac.yaml).
- A missing TLS secret can break a specific Ingress, but it is not enough to
  explain multiple `haproxy-public` Ingresses with ready certificates and empty
  `status.loadBalancer`.
- The controller version pin lives in
  [manifests/haproxy-public-deployment.yaml](manifests/haproxy-public-deployment.yaml).

Known staging observation:
- `haproxytech/kubernetes-ingress:3.2.6` was observed reconciling HAProxy
  backend configuration while leaving `Ingress.status.loadBalancer` empty.
  This folder now pins `3.2.8` for follow-up validation.

Apply and watch the rollout:

```bash
kubectl apply -k common/haproxy-ingress/
kubectl -n ingress-nginx rollout status deploy/haproxy-public-controller
```

---

## FAQ

**Do I need a second controller for two different status IPs?**  
Yes. One controller can serve multiple classes, but it only publishes one IP (from its `--publish-service`).

**Do I need a ConfigMap?**  
Only if you want to tweak NGINX settings. You can add  
`--configmap=$(POD_NAMESPACE)/haproxy-public-controller` later and create a matching ConfigMap.

**Can I enable PROXY protocol?**  
Yes—see “Optional: PROXY protocol” above.
# Remote access

If you are off the cluster's network, tunnel through a jump host.

## Option A — SOCKS proxy (best for `kubectl`)

Routes all traffic through the jump host.

```bash
ssh -D 1080 -C -q -N <user>@<jump-host>
export HTTPS_PROXY=socks5://127.0.0.1:1080
kubectl get pods -A
```

> Note: the Argo CD CLI's gRPC dialer doesn't speak SOCKS reliably
> (`socks connect unix: network not implemented`). For `argocd`, use
> Option B.

## Option B — Local port-forward + `/etc/hosts` (Argo CD CLI / UI)

The Argo CD Ingress is `Host`-routed, so the local hostname must match
the public one. The cleanest way is to combine SOCKS (for `kubectl`) and
a TCP forward (for the CLI / browser) on a single SSH command:

```bash
ssh -D 1080 \
    -L 8443:<argocd-host>:443 \
    -C -q -N <user>@<jump-host>
```

Map the hostname locally so SNI, `Host` header and TLS cert all line up:

```bash
echo "127.0.0.1   <argocd-host>" | sudo tee -a /etc/hosts
```

Now log in. Use `--insecure` only while the Ingress is still on a
placeholder hostname / self-signed cert; drop it once / if cert-manager has
issued a real certificate:

```bash
argocd login <argocd-host>:8443 --insecure --grpc-web --username admin
```

Browser: `https://<argocd-host>:8443/` (accept the cert warning while
on a placeholder hostname).

Important: once you add `<argocd-host>` to `/etc/hosts`, the bare URL
`https://<argocd-host>/` resolves to `127.0.0.1`. If you only forwarded local
port `8443`, nothing is listening on local `443`, so Firefox / Chrome will fail
unless you include `:8443` in the URL.

When you no longer need it, remove the `/etc/hosts` line.

## Browser access to `haproxy-public` endpoints on staging infra (MIP team)

For services exposed through the `haproxy-public` controller on the staging cluster, browser
access works only if one of these is true:

- Your source IP is allowlisted on the public endpoint.
- You run a SOCKS tunnel through the jump host and send browser traffic through
    it, for example with FoxyProxy:

```bash
ssh -D 5011 -C -q -N <user>@<jump-host>
```

Then configure FoxyProxy to use the local SOCKS proxy on
`127.0.0.1:5011` for the staging hostnames you want to reach.

## Option C — `kubectl port-forward` (fallback)

Works without an Ingress, but the data path goes through the apiserver
which can be flaky for long-lived gRPC streams.

```bash
kubectl -n argocd-mip-team port-forward svc/argocd-server 8080:80
argocd login localhost:8080 --plaintext --grpc-web
```

(`--plaintext`, not `--insecure` — `argocd-server` runs with
`--insecure` so the in-cluster Service speaks plain HTTP on port 80.)


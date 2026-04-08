# macOS: DNS + ArgoCD Reachability (dev/dev-single/prod zones)

This guide is for the common case where some `*.{dev,dev-single,prod}.internal.example.com` hostnames do not resolve or the Argo CD CLI fails from macOS.

## 1) Check which DNS server macOS uses for each zone

```bash
scutil --dns | rg -n "dev.internal.example.com|dev-single.internal.example.com|prod.internal.example.com|nameserver\\["
```

If you see `dev.internal.example.com` or `dev-single.internal.example.com` pointing at an IP that is not reachable from your current network (common when switching between OrbStack and Proxmox/Talos), look for a stale resolver override.

## 2) Check `/etc/resolver` overrides (common root cause)

```bash
ls -la /etc/resolver || true
sudo sh -c 'for f in /etc/resolver/*; do echo "### $f"; cat "$f"; echo; done' || true
```

If `/etc/resolver/dev.internal.example.com` (or `/etc/resolver/dev-single.internal.example.com`) exists and points at an unreachable IP, either remove it or change it to your primary DNS (Pi-hole):

```bash
sudo rm -f /etc/resolver/dev.internal.example.com /etc/resolver/dev-single.internal.example.com
# or:
sudo mkdir -p /etc/resolver
cat <<'RESOLVER' | sudo tee /etc/resolver/dev.internal.example.com >/dev/null
nameserver 198.51.100.3
port 53
RESOLVER
cat <<'RESOLVER' | sudo tee /etc/resolver/dev-single.internal.example.com >/dev/null
nameserver 198.51.100.3
port 53
RESOLVER
```

Flush caches:

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

## 3) Validate name resolution + routing

```bash
dig +time=1 +tries=1 argocd.prod.internal.example.com A
dig +time=1 +tries=1 argocd.dev.internal.example.com A
dig +time=1 +tries=1 argocd.dev-single.internal.example.com A
```

If DNS is broken but you still want to validate ingress reachability, bypass DNS with `curl --resolve` (prod example):

```bash
KUBECONFIG=tmp/kubeconfig-prod
vip="$(kubectl -n istio-system get svc public-gateway-istio -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl --cacert shared/certs/deploykube-root-ca.crt -fsSI \
  --resolve argocd.prod.internal.example.com:443:${vip} \
  https://argocd.prod.internal.example.com/healthz | head -n 20
```

If `dig` works but your app still fails, ensure you have a route to the cluster LAN:

```bash
route -n get 198.51.100.3 | rg -n "interface:|gateway:"
```

## 4) Validate TLS trust with the repo CA bundle

```bash
curl --cacert shared/certs/deploykube-root-ca.crt -fsS https://argocd.prod.internal.example.com/healthz
curl --cacert shared/certs/deploykube-root-ca.crt -fsS https://grafana.prod.internal.example.com/api/health
```

If `curl` fails with `x509: certificate signed by unknown authority`, your `shared/certs/deploykube-root-ca.crt` is not the same root CA the cluster uses. In DeployKube, the cluster root is mirrored into `cert-manager/step-ca-root-ca` and should match `shared/certs/deploykube-root-ca.crt`.

## 5) Argo CD CLI: always use HTTPS with `--grpc-web`

The Argo CD ingress may not serve the gRPC-web API over plain HTTP. If your ArgoCD CLI context is configured with `plain-text: true`, it can end up calling `http://...` and return `404`.

Use:

```bash
argocd context argocd.prod.internal.example.com
argocd app get platform-apps --grpc-web --server-crt shared/certs/deploykube-root-ca.crt
```

## 6) Workaround: use `--port-forward` when DNS is broken

If the zone forwarding (Pi-hole / `/etc/resolver`) is broken and `argocd.prod.int...` can’t be resolved, you can still use the Argo CD CLI by port-forwarding to the in-cluster API server:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
argocd app get platform-apps \
  --grpc-web \
  --port-forward \
  --port-forward-namespace argocd \
  --plaintext
```

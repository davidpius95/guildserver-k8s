# Edge & Ingress — public URLs for cluster apps

Completes the north–south path so a Kubernetes app is reachable at
`https://<sub>.guildserver.io`.

## The full path

```
User ──HTTPS──▶ Cloudflare ──tunnel──▶ Caddy (CT910, :80) ──HTTP (Host preserved)──▶
   ingress-nginx (LB 192.168.8.63) ──▶ Service ──▶ Pod
```

- **MetalLB** ([`../metallb/pool.yaml`](../metallb/pool.yaml)) gives `type=LoadBalancer`
  Services a real LAN IP (pool `192.168.8.63-.69`, L2 mode).
- **ingress-nginx** takes the first pool IP **`192.168.8.63`** (pinned via the
  `metallb.universe.tf/loadBalancerIPs` annotation) and is the **default IngressClass**.
- **Caddy** (the existing Guild-A edge) routes `<sub>.guildserver.io` to that LB IP. Caddy
  preserves the `Host` header, so ingress-nginx matches the Ingress `host:` rule.

## Add a public app

1. Give the app an `Ingress` with `ingressClassName: nginx` and `host: <sub>.guildserver.io`
   (see [`../../apps/demo/demo.yaml`](../../apps/demo/demo.yaml)).
2. Point the edge at ingress-nginx (once per subdomain; the `*.guildserver.io` wildcard
   means **no Cloudflare change**):
   ```bash
   NO_CF=1 ./ingress/route add <sub> 192.168.8.63:80    # in the ProxmoxMCP-Plus repo
   ```
3. Visit `https://<sub>.guildserver.io`.

## Install

```bash
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
kubectl apply -f ../metallb/pool.yaml
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace -f values.yaml
```

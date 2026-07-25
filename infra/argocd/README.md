# Argo CD — GitOps delivery

Argo CD makes **Git the source of truth**: it continuously compares the cluster to this
repo and reconciles any drift. From here, `git push` is the deploy — nothing is applied by
hand.

## The app-of-apps pattern

```
argocd/root-app.yaml            (applied once by hand)
   └─ watches argocd/applications/
        └─ demo.yaml            → deploys apps/demo/  into namespace "demo"
```

Add a new app later = drop an `Application` file in `argocd/applications/` and `git push`.
The root app notices and deploys it. No cluster access needed for day-to-day delivery.

## Install

```bash
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace -f values.yaml
kubectl apply -f ingress.yaml                       # UI at argocd.guildserver.io
kubectl apply -f ../../argocd/root-app.yaml         # bootstrap GitOps (once)
NO_CF=1 ./ingress/route add argocd 192.168.8.63:80  # edge route (ProxmoxMCP-Plus repo)
```

- Runs `server.insecure: true` — TLS is terminated at the Cloudflare edge; ingress-nginx
  speaks plain HTTP to `argocd-server:80`.
- Initial admin password: `kubectl -n argocd get secret argocd-initial-admin-secret -o
  jsonpath='{.data.password}' | base64 -d` (user `admin`). Rotate/disable after first login.

## Verify GitOps

Edit `apps/demo/demo.yaml` (e.g. bump `replicas`), `git push`, and watch Argo CD sync the
change into the cluster within a couple of minutes — or instantly in the UI with **Sync**.
Editing a live resource by hand triggers **self-heal** back to the Git state.

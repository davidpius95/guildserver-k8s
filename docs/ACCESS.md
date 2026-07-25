# Access Guide

Everything you need to reach and operate the cluster. **No secrets live in this repo** —
they're all in the credentials vault on the Mac:

```
~/.config/guildserver/INFRA-SECRETS.md      (chmod 0600)
```

Retrieve any secret with `grep`, e.g. `grep -A3 "Grafana admin" ~/.config/guildserver/INFRA-SECRETS.md`.

---

## Public web endpoints (via Cloudflare → Caddy → ingress-nginx `192.168.8.63`)

| URL | What it is | How to log in |
|-----|-----------|---------------|
| https://k8s.guildserver.io | Demo app (`nginxdemos/hello`) | none (public demo) |
| https://stateful.guildserver.io | Stateful demo (persists on Ceph) | none (public demo) |
| https://argocd.guildserver.io | **ArgoCD** — GitOps / app delivery | user `admin`, password in vault → *ArgoCD admin* |
| https://grafana.guildserver.io | **Grafana** — metrics & logs dashboards | user `admin`, password in vault → *Grafana admin* |
| https://headlamp.guildserver.io | **Headlamp** — cluster management UI | open cluster `main` → **Token** → paste token (see below) |

All five resolve through the existing `*.guildserver.io` Cloudflare tunnel → Caddy (CT 910)
→ ingress-nginx. Add another app URL with (in the `ProxmoxMCP-Plus` repo):
`NO_CF=1 ./ingress/route add <sub> 192.168.8.63:80`.

### Headlamp token (copy to clipboard)

```bash
ssh -i ~/.ssh/proxmox_guild_a guildvm@192.168.8.60 \
  'kubectl --kubeconfig ~/.kube/config-direct -n headlamp get secret headlamp-admin-token -o jsonpath="{.data.token}" | base64 -d' | pbcopy
```

Then paste (⌘V) into Headlamp's **Token** auth screen. Session lasts 24h. (Also stored in
vault → *Headlamp K8s UI*.)

---

## Cluster admin (kubectl)

`kubectl` runs on the control-plane node; SSH in and use it:

```bash
ssh -i ~/.ssh/proxmox_guild_a guildvm@192.168.8.60
export KUBECONFIG=~/.kube/config          # via the VIP 192.168.8.59
# If the VIP is ever flapping, use the direct-to-node config:
export KUBECONFIG=~/.kube/config-direct   # server https://192.168.8.60:6443
kubectl get nodes
```

To run `kubectl`/`helm` from elsewhere (e.g. Gitpod), copy `~/.kube/config` off cp-1 and set
`KUBECONFIG` to it — it targets the API VIP `192.168.8.59:6443`. **Do not commit a kubeconfig.**

- **API endpoint (VIP):** `https://192.168.8.59:6443`
- **Nodes:** cp-1 `192.168.8.60`, w-1 `192.168.8.61`, w-2 `192.168.8.62`
- **SSH:** `ssh -i ~/.ssh/proxmox_guild_a guildvm@<node-ip>` (Proxmox hosts: `root@<node-ip>`)

---

## Internal-only services (no public URL)

| Service | Address (in-cluster) | Access | Secret |
|---------|----------------------|--------|--------|
| MinIO API | `http://minio.minio.svc:9000` | Velero uses it internally | vault → *MinIO* |
| MinIO console | port 9001 | `kubectl -n minio port-forward svc/minio 9001:9001` then http://localhost:9001 | vault → *MinIO* |
| Hubble UI | `kubectl -n kube-system port-forward svc/hubble-ui 12000:80` | http://localhost:12000 | none |
| Prometheus | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` | http://localhost:9090 | none |

---

## Where each secret lives in the vault

| Vault section | Used for |
|---------------|----------|
| *Ceph cephx: client.k8s* | Ceph-CSI storage (`csi-rbd-secret`) |
| *ArgoCD admin* | https://argocd.guildserver.io |
| *Grafana admin* | https://grafana.guildserver.io |
| *MinIO* | Velero backup backend |
| *Headlamp K8s UI* | https://headlamp.guildserver.io login token |

All k8s Secrets in the cluster reference these values; the repo only ever contains
`*.example.yaml` templates and `existingSecret:` references — never the values themselves.

---

## Security notes

- The Headlamp/ArgoCD/Grafana UIs are internet-facing but gated by their own auth. Keep the
  vault (and these credentials) private.
- The Headlamp login token is **cluster-admin** — anyone with it controls the cluster.
- For defense-in-depth, put **Cloudflare Access** (email/SSO) in front of the admin UIs so
  there's an auth gate at the edge before the app loads.

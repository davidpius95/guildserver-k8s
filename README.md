# guildserver-k8s

[![validate](https://github.com/davidpius95/guildserver-k8s/actions/workflows/validate.yml/badge.svg)](https://github.com/davidpius95/guildserver-k8s/actions/workflows/validate.yml)
[![Open in Gitpod](https://img.shields.io/badge/Gitpod-ready--to--code-blue?logo=gitpod)](https://gitpod.io/#https://github.com/davidpius95/guildserver-k8s)

An **industry-standard, self-hosted Kubernetes platform** built with `kubeadm` on the
5-node **Guild-A** Proxmox cluster — provisioned as infrastructure-as-code, and grown
layer by layer toward everything an enterprise runs: HA control plane, eBPF networking,
Ceph-backed persistent storage, ingress at the edge, GitOps, observability, and policy.

This repo is both the **source of truth** for the platform and a **learning log** of how
it was built.

> 📐 **[Full architecture & design doc → `docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** —
> every layer, component, and dependency explained, the enterprise problem each one solves,
> and diagrams of the stack, communication flows, networking, storage, edge, and GitOps.
>
> 📚 **[Learning journal → `docs/LEARNING-JOURNAL.md`](docs/LEARNING-JOURNAL.md)** — the
> teaching companion: the reasoning at each step, every bug→diagnosis→fix, how it maps to
> enterprise/datacenter practice, and a path to becoming an expert.

## Cluster at a glance

| | |
|---|---|
| Kubernetes | **v1.36.3** (kubeadm) |
| Nodes | 1 control-plane + 2 workers (VMs on Proxmox/Ceph) |
| Runtime | containerd 2.2.2 · runc 1.4.0 |
| CNI | **Cilium** (eBPF) + Hubble |
| HA endpoint | **kube-vip** VIP `192.168.8.59:6443` |
| OS | Ubuntu 26.04 LTS (kernel 7.0) |

Full node layout and versions: [`clusters/guild-a/cluster-info.md`](clusters/guild-a/cluster-info.md).

## Repo layout

```
.
├── scripts/            # Idempotent provisioning (host prep, control-plane bootstrap, CNI)
├── infra/              # Platform layer as code (Cilium values today; MetalLB, ceph-csi, ingress next)
├── apps/               # Workload manifests — GitOps source of truth (watched by ArgoCD, Phase 7)
├── clusters/guild-a/   # Cluster facts, layout, and cluster-scoped config
├── docs/               # Architecture doc + diagrams
├── .github/workflows/  # CI: yamllint, shellcheck, kubeconform
└── .gitpod.yml         # Browser dev env preloaded with kubectl/helm/cilium/k9s
```

## How the cluster was bootstrapped

Everything is scripted and re-runnable. Order:

1. **`scripts/k8s-node-prep.sh`** — run on every node. Disables swap, loads kernel modules
   (`overlay`, `br_netfilter`), sets sysctls, installs & configures containerd
   (`SystemdCgroup=true`), installs `kubeadm`/`kubelet`/`kubectl` pinned to v1.36 and holds them.
2. **`scripts/bootstrap-cp.sh`** — run on the first control-plane node. Lays down the
   kube-vip static pod for the VIP, then `kubeadm init` against the VIP endpoint with
   `--upload-certs`, writes kubeconfig, and saves the worker join command.
3. **`scripts/install-cilium.sh`** — installs Helm + the Cilium CNI (values in
   [`infra/cilium/values.yaml`](infra/cilium/values.yaml)) and Hubble.
4. Workers join with the `kubeadm join` command emitted in step 2.

> Secrets (join tokens, certificate keys, kubeconfigs) are generated **at runtime on the
> nodes** and are never stored in this repo — see `.gitignore`.

## Roadmap

- [x] **Phase 1** — Provision VMs (1 control-plane + 2 workers)
- [x] **Phase 2** — Host prep: containerd + kube tooling
- [x] **Phase 3** — Control plane (kube-vip VIP + kubeadm init + Cilium CNI)
- [x] **Phase 4** — Join worker nodes (2 workers, verified end-to-end)
- [x] **Phase 5** — Ceph-CSI dynamic persistent storage (verified: PVC → RBD image in Ceph → pod read/write)
- [x] **Phase 6** — MetalLB + ingress-nginx wired to the Cloudflare edge (live: `https://k8s.guildserver.io`)
- [x] **Phase 7** — GitOps with ArgoCD (app-of-apps live; `git push` deploys; UI at `argocd.guildserver.io`)
- [ ] **Phase 8** — Observability: Prometheus + Grafana + Loki
- [ ] **Phase 9** — Security & policy: RBAC, NetworkPolicies, Kyverno, secrets
- [ ] **Phase 10** — Sample app end-to-end + Day-2 (Velero backups, HA growth, upgrades)

## Using this repo

- **Gitpod:** click the badge — you get a browser IDE with `kubectl`, `helm`, `cilium`,
  and `k9s` preinstalled. Paste in a `KUBECONFIG` (never commit it) to talk to the cluster.
- **CI/CD:** every push runs YAML lint, shellcheck, and `kubeconform` manifest validation.
  As GitOps matures, ArgoCD reconciles `apps/` on merge to `main`.

## License

Personal infrastructure / learning project.

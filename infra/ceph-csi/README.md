# Ceph-CSI — dynamic persistent storage

Wires Kubernetes to the existing Guild-A Ceph cluster so `PersistentVolumeClaim`s
dynamically provision RBD volumes. This is what lets stateful workloads (databases,
queues) run with real, replicated, network-attached storage.

## Topology

```
PVC ──▶ StorageClass "ceph-rbd" ──▶ rbd.csi.ceph.com ──▶ pool "k8s-rbd" (size=3) ──▶ Ceph
```

- **Dedicated pool `k8s-rbd`** (`size=3, min_size=2`) — isolated from the `ceph-vm` pool
  that holds Proxmox VM disks.
- **Scoped cephx user `client.k8s`** — access to `k8s-rbd` only:
  ```
  ceph auth get-or-create client.k8s \
    mon 'profile rbd' osd 'profile rbd pool=k8s-rbd' mgr 'profile rbd pool=k8s-rbd'
  ```
- Ceph FSID (`clusterID`) and mon IPs are in [`values.yaml`](values.yaml) and
  [`storageclass.yaml`](storageclass.yaml).

## Install

```bash
helm repo add ceph-csi https://ceph.github.io/csi-charts
helm upgrade --install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
  -n ceph-csi --create-namespace -f values.yaml

# secret (NOT committed — key from Ceph):
KEY=$(ssh root@<mon-node> 'ceph auth get-key client.k8s')
kubectl -n ceph-csi create secret generic csi-rbd-secret \
  --from-literal=userID=k8s --from-literal=userKey="$KEY"

kubectl apply -f storageclass.yaml
```

Node prerequisite: the `rbd` kernel module must load on every node (persisted via
`/etc/modules-load.d/rbd.conf`).

## Verify

```bash
kubectl apply -f example-pvc.yaml
kubectl get pvc ceph-test-pvc          # -> Bound
kubectl exec ceph-test-pod -- cat /data/proof.txt
rbd -p k8s-rbd ls                       # (on a Ceph node) -> shows the csi-vol-* image
```

## Files

| File | Purpose |
|------|---------|
| `values.yaml` | Helm values — Ceph FSID + monitors |
| `storageclass.yaml` | Default `ceph-rbd` StorageClass |
| `secret.example.yaml` | Template for the cephx secret (real key applied out-of-band) |
| `example-pvc.yaml` | Smoke-test PVC + pod |

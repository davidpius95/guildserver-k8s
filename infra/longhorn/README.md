# Longhorn — cluster storage (Guild-B)

```
PVC ──▶ StorageClass "longhorn" ──▶ driver.longhorn.io ──▶ replicas on worker disks
                                                            (/var/lib/longhorn, 2 copies)
```

## Why this replaced Ceph-CSI

The k8s nodes originally ran on **Guild-A** and used its Ceph cluster via Ceph-CSI.
When the nodes were live-migrated to **Guild-B**, the CSI driver kept reaching back to
Guild-A's monitors (`192.168.8.125/.155/.112`). That worked — both clusters share an L2
subnet — but it left compute on Guild-B permanently depending on Guild-A for storage:
if Guild-A went down, every PV in this cluster became unavailable.

Longhorn keeps the replicas on the cluster's own worker nodes, so Guild-B is
self-contained.

## Layout

| Node | Role | Longhorn disk |
|---|---|---|
| `k8s-cp-1` | control-plane (tainted `NoSchedule`) | none |
| `k8s-w-1` | worker | 100G → `/var/lib/longhorn` |
| `k8s-w-2` | worker | 100G → `/var/lib/longhorn` |

Two schedulable workers means **`replicaCount: 2`** is the ceiling. There is no spare
node to rebuild onto if one worker is lost, so a volume degrades until it returns.
Adding a third worker and moving to 3 replicas is the obvious next improvement.

## Node prerequisites

Longhorn needs `open-iscsi` running on every node, and `nfs-common` for RWX volumes:

```bash
systemctl enable --now iscsid
apt-get install -y nfs-common
```

The dedicated disk is mounted by label so it survives device renaming:

```
LABEL=longhorn /var/lib/longhorn ext4 defaults,noatime 0 2
```

## Install

```bash
helm repo add longhorn https://charts.longhorn.io
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace -f values.yaml
```

## Notes

- `reclaimPolicy` on the default class is `Delete` — deleting a PVC destroys the volume.
  Snapshot or back up anything you care about first.
- Velero's backup target (MinIO) runs **inside this cluster** on a Longhorn volume. That
  is a circular dependency: MinIO cannot restore itself. Point Velero at off-cluster
  storage before relying on it for disaster recovery.

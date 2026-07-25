# Guild-A Cluster — Facts & Layout

Kubernetes cluster built with **kubeadm** on the 5-node Guild-A Proxmox VE cluster.

## Versions

| Component | Version |
|-----------|---------|
| Kubernetes | v1.36.3 |
| Container runtime | containerd 2.2.2 |
| runc | 1.4.0 |
| CNI | Cilium (Helm, eBPF) + Hubble |
| Control-plane VIP | kube-vip v1.2.1 (ARP mode) |
| Base OS | Ubuntu 26.04 LTS (kernel 7.0) |

## Nodes

All nodes are QEMU VMs cloned from Proxmox template 9000, on the flat `vmbr0`
(192.168.8.0/24) network, rootfs on shared Ceph RBD (`ceph-vm`), `onboot=1`, swap off.

| VM ID | Hostname | Proxmox node | Role | vCPU | RAM | IP |
|-------|----------|--------------|------|------|-----|-----|
| 120 | k8s-cp-1 | nodeD | control-plane | 2 | 4 GB | 192.168.8.60 |
| 121 | k8s-w-1  | nodeE | worker | 2 | 6 GB | 192.168.8.61 |
| 122 | k8s-w-2  | nodeB | worker | 2 | 6 GB | 192.168.8.62 |

- **Control-plane endpoint (VIP): `192.168.8.59:6443`** — stable API address so
  control-plane nodes can be added for HA without re-issuing certs or reconfiguring clients.
- **Pod CIDR:** `10.244.0.0/16`  ·  **Service CIDR:** `10.96.0.0/12` (kubeadm default)

## Networking model

Nodes sit on the home flat L2 segment (gateway `192.168.8.1`). DNS upstream is set via a
systemd-resolved drop-in (`1.1.1.1`/`8.8.8.8`) because cloud-init assigned static IPs
without a nameserver.

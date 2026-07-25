#!/usr/bin/env bash
# Idempotent kubeadm host prep for Guild-A k8s nodes. Ubuntu 26.04, k8s v1.36.
set -euo pipefail
K8S_MINOR="v1.36"

echo "### [1/6] kernel modules (overlay, br_netfilter)"
cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

echo "### [2/6] sysctl (bridge netfilter + ip_forward)"
cat >/etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

echo "### [3/6] ensure swap off (belt-and-suspenders)"
swapoff -a || true
sed -i.bak '/\bswap\b/ s/^/#/' /etc/fstab 2>/dev/null || true

echo "### [4/6] install + configure containerd (SystemdCgroup=true)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq containerd runc apt-transport-https ca-certificates curl gpg >/dev/null
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd >/dev/null 2>&1

echo "### [5/6] add k8s apt repo ${K8S_MINOR} + install kubeadm/kubelet/kubectl"
mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl >/dev/null
apt-mark hold kubelet kubeadm kubectl >/dev/null
systemctl enable --now kubelet >/dev/null 2>&1 || true

echo "### [6/6] versions"
echo -n "  containerd: "; containerd --version | awk '{print $3}'
echo -n "  runc:       "; runc --version | head -1 | awk '{print $3}'
echo -n "  kubeadm:    "; kubeadm version -o short
echo -n "  SystemdCgroup: "; grep -c 'SystemdCgroup = true' /etc/containerd/config.toml
echo "### DONE on $(hostname)"

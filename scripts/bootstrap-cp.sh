#!/usr/bin/env bash
# Bootstrap the k8s control plane on k8s-cp-1. kube-vip VIP + kubeadm init.
set -euo pipefail
VIP=192.168.8.59
IFACE=eth0
KVVERSION=v1.2.1
K8SVER=v1.36.3
POD_CIDR=10.244.0.0/16

echo "### [1/4] generate kube-vip static pod manifest (ARP, controlplane, no leaderElection)"
mkdir -p /etc/kubernetes/manifests
ctr image pull ghcr.io/kube-vip/kube-vip:${KVVERSION} >/dev/null
ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KVVERSION} vip \
  /kube-vip manifest pod \
    --interface ${IFACE} \
    --address ${VIP} \
    --controlplane \
    --arp \
  > /etc/kubernetes/manifests/kube-vip.yaml
echo "  wrote /etc/kubernetes/manifests/kube-vip.yaml ($(wc -l </etc/kubernetes/manifests/kube-vip.yaml) lines)"

echo "### [2/4] kubeadm init (endpoint ${VIP}:6443, pod-cidr ${POD_CIDR})"
kubeadm init \
  --control-plane-endpoint "${VIP}:6443" \
  --upload-certs \
  --pod-network-cidr "${POD_CIDR}" \
  --kubernetes-version "${K8SVER}" \
  | tee /root/kubeadm-init.log

echo "### [3/4] set up kubeconfig for root and guildvm"
mkdir -p /root/.kube && cp -f /etc/kubernetes/admin.conf /root/.kube/config
install -d -o guildvm -g guildvm /home/guildvm/.kube
cp -f /etc/kubernetes/admin.conf /home/guildvm/.kube/config
chown guildvm:guildvm /home/guildvm/.kube/config

echo "### [4/4] persist join command"
kubeadm token create --print-join-command > /root/worker-join.sh 2>/dev/null
chmod +x /root/worker-join.sh
echo "  worker join command saved to /root/worker-join.sh:"
cat /root/worker-join.sh
echo "### CONTROL PLANE INIT DONE"

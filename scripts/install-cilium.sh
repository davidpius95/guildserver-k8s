#!/usr/bin/env bash
# Install Helm + Cilium CNI on the control plane. Run as root on k8s-cp-1.
set -euo pipefail
export KUBECONFIG=/etc/kubernetes/admin.conf
VIP=192.168.8.59

echo "### [1/5] install Helm"
if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
fi
helm version --short

echo "### [2/5] install cilium CLI"
if ! command -v cilium >/dev/null 2>&1; then
  CILIUM_CLI_VERSION=$(curl -fsS https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
  curl -fsSL --remote-name-all "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
  tar xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
  rm -f cilium-linux-amd64.tar.gz
fi
cilium version --client

echo "### [3/5] helm repo"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "### [4/5] helm install cilium (cluster-pool 10.244.0.0/16, API via VIP)"
helm install cilium cilium/cilium -n kube-system \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.244.0.0/16}' \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set k8sServiceHost=${VIP} \
  --set k8sServicePort=6443 \
  --set kubeProxyReplacement=false \
  --set operator.replicas=1 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

echo "### [5/5] wait for Cilium to be ready"
cilium status --wait --wait-duration 4m || true
echo "--- nodes ---"; kubectl get nodes -o wide
echo "--- kube-system pods ---"; kubectl get pods -n kube-system
echo "### CILIUM INSTALL DONE"

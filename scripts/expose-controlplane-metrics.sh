#!/usr/bin/env bash
# Expose control-plane component metrics so Prometheus can scrape them.
#
# kubeadm binds these four endpoints to 127.0.0.1 by default, which means a
# Prometheus running *in a pod* can never reach them. kube-prometheus-stack ships
# ServiceMonitors for all four regardless, so they sit permanently "down" and the
# corresponding dashboards and alerts are silently blind:
#
#   kube-proxy              :10249   metricsBindAddress: ""      (defaults to 127.0.0.1)
#   kube-controller-manager :10257   --bind-address=127.0.0.1
#   kube-scheduler          :10259   --bind-address=127.0.0.1
#   etcd                    :2381    --listen-metrics-urls=http://127.0.0.1:2381
#
# SECURITY NOTE — read before running.
#   controller-manager and scheduler serve /metrics over HTTPS with authn/authz,
#   so widening the bind address still requires a valid token.
#   etcd's :2381 is a metrics-only listener — it exposes no client/peer API and
#   no key material, but it does reveal cluster internals.
#   kube-proxy's :10249 is plain HTTP with NO authentication. On a trusted LAN
#   that is usually acceptable; on an untrusted network, firewall these ports to
#   the monitoring subnet instead of leaving them open.
#
# Run on the control-plane node as root. Static pod manifest edits are picked up
# by the kubelet automatically — no restart command needed.
#
# IMPACT: controller-manager and scheduler restart (seconds, harmless — brief
# leader election). etcd also restarts; on a SINGLE-MEMBER etcd that makes the
# Kubernetes API briefly unavailable (~15-30s). Running workloads are unaffected
# because kubelets operate independently of the API server. Pass --skip-etcd to
# leave etcd alone.

set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
MANIFESTS=/etc/kubernetes/manifests
SKIP_ETCD=0
[[ "${1:-}" == "--skip-etcd" ]] && SKIP_ETCD=1

ts=$(date +%Y%m%d-%H%M%S)
backup() { cp -a "$1" "/root/$(basename "$1").bak-${ts}"; }

echo "### [1/4] kube-controller-manager --bind-address"
if grep -q 'bind-address=127.0.0.1' "${MANIFESTS}/kube-controller-manager.yaml"; then
  backup "${MANIFESTS}/kube-controller-manager.yaml"
  sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' "${MANIFESTS}/kube-controller-manager.yaml"
  echo "    updated"
else
  echo "    already exposed, skipping"
fi

echo "### [2/4] kube-scheduler --bind-address"
if grep -q 'bind-address=127.0.0.1' "${MANIFESTS}/kube-scheduler.yaml"; then
  backup "${MANIFESTS}/kube-scheduler.yaml"
  sed -i 's/--bind-address=127.0.0.1/--bind-address=0.0.0.0/' "${MANIFESTS}/kube-scheduler.yaml"
  echo "    updated"
else
  echo "    already exposed, skipping"
fi

echo "### [3/4] kube-proxy metricsBindAddress"
# The ConfigMap is the source of truth; the DaemonSet must be rolled to pick it up.
if kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -q 'metricsBindAddress: ""'; then
  kubectl -n kube-system get cm kube-proxy -o yaml \
    | sed 's/metricsBindAddress: ""/metricsBindAddress: "0.0.0.0:10249"/' \
    | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart daemonset kube-proxy
  kubectl -n kube-system rollout status daemonset kube-proxy --timeout=180s
  echo "    updated + rolled"
else
  echo "    already exposed, skipping"
fi

echo "### [4/4] etcd --listen-metrics-urls"
if [[ "${SKIP_ETCD}" == "1" ]]; then
  echo "    --skip-etcd given, leaving etcd untouched"
elif grep -q 'listen-metrics-urls=http://127.0.0.1:2381' "${MANIFESTS}/etcd.yaml"; then
  echo "    NOTE: single-member etcd restarts here; API blips for ~15-30s"
  backup "${MANIFESTS}/etcd.yaml"
  sed -i 's#--listen-metrics-urls=http://127.0.0.1:2381#--listen-metrics-urls=http://0.0.0.0:2381#' "${MANIFESTS}/etcd.yaml"
  echo "    updated"
else
  echo "    already exposed, skipping"
fi

echo
echo "### done. Backups in /root/*.bak-${ts}"
echo "### Prometheus re-scrapes within ~30s. Verify with:"
echo "###   kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \\"
echo "###     wget -qO- 'http://localhost:9090/api/v1/query?query=up{job=~\"kube-proxy|kube-etcd|kube-scheduler|kube-controller-manager\"}'"

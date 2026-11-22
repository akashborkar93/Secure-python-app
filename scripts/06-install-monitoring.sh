#!/usr/bin/env bash
# =============================================================================
# 06-install-monitoring.sh - Install Prometheus + Alertmanager + Grafana
# =============================================================================
# Run ON the server from the repo root:   bash scripts/06-install-monitoring.sh

set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"
CHART_VERSION="93.7.0"   # kube-prometheus-stack version, pinned

echo "==> 1/5 Adding the Prometheus community Helm repository"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "==> 2/5 Creating the 'monitoring' namespace"
# 'gateway-access=true' lets Grafana's HTTPRoute attach to our shared Gateway.
# We do NOT enforce the strict Pod Security level here because node-exporter
# legitimately needs host access to read server metrics.
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace monitoring gateway-access=true --overwrite

echo "==> 3/5 Creating a random Grafana admin password (stored only in the cluster + a private file)"
if ! kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1; then
  PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin --from-literal=admin-password="$PASSWORD"
  # Save a copy readable only by you, so you can log in. Never commit this file.
  umask 077
  echo "$PASSWORD" > "$HOME/.grafana-admin-password"
fi

echo "==> 4/5 Installing kube-prometheus-stack (takes a few minutes)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$CHART_VERSION" -n monitoring \
  -f platform/monitoring-values.yaml \
  --wait --timeout 600s

echo "==> 5/5 Loading our app dashboard and the Grafana route"
kubectl create configmap demo-app-dashboard -n monitoring \
  --from-file=demo-app.json=platform/dashboards/demo-app.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl label configmap demo-app-dashboard -n monitoring grafana_dashboard=1 --overwrite
kubectl apply -f platform/grafana-httproute.yaml

kubectl get pods -n monitoring

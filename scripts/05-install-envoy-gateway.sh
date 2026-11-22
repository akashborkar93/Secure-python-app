#!/usr/bin/env bash
# =============================================================================
# 05-install-envoy-gateway.sh - Install Envoy Gateway (our Gateway API controller)
# =============================================================================
# Run ON the server:   bash 05-install-envoy-gateway.sh   (from the repo root)
#
# Background for beginners:
#   * "Gateway API" is the Kubernetes standard for letting outside traffic in.
#   * It only defines objects (Gateway, HTTPRoute). A CONTROLLER must do the work.
#   * Envoy Gateway is that controller. It starts an Envoy proxy that receives traffic.
#
# Important detail: k3s already installed the standard Gateway API CRDs
# (CRD = "definition of a new Kubernetes object type"). Installing them twice would
# clash, so we install ONLY Envoy Gateway's own CRDs, then the controller without CRDs.

set -euo pipefail
export KUBECONFIG="$HOME/.kube/config"
EG_VERSION="v1.10.0"   # pinned so everyone gets the same thing

echo "==> 1/4 Installing Envoy Gateway's own CRDs (Gateway API CRDs are left to k3s)"
# Why not "helm install"? The CRD bundle is bigger than 1 MB, which is more than Helm can
# store as a release record. So we render it with "helm template" and apply it with
# kubectl using --server-side (also needed because the CRDs are large).
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "$EG_VERSION" \
  --set crds.gatewayAPI.enabled=false \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

echo "==> 2/4 Installing the Envoy Gateway controller"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$EG_VERSION" \
  -n envoy-gateway-system --create-namespace \
  --set crds.enabled=false \
  -f platform/envoy-gateway-values.yaml \
  --wait --timeout 180s

echo "==> 3/4 Creating the GatewayClass and the shared Gateway"
kubectl apply -f platform/gateway.yaml

echo "==> 4/4 Waiting for the Gateway to be programmed (ready)"
kubectl wait --for=condition=Programmed gateway/shared-gateway \
  -n envoy-gateway-system --timeout=180s
kubectl get gatewayclass,gateway -A
kubectl get pods,svc -n envoy-gateway-system

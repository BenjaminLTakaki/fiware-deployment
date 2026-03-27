#!/bin/bash
# ============================================================================
# FIWARE Monitoring Stack Deployment Script
# ============================================================================
# Deploys Prometheus, Grafana, and Loki for research-grade observability.
#
# Usage:
#   ./deploy-monitoring.sh [--skip-prometheus] [--skip-loki]
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_DIR="${SCRIPT_DIR}/../monitoring"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
SKIP_PROMETHEUS=false
SKIP_LOKI=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-prometheus)
            SKIP_PROMETHEUS=true
            shift
            ;;
        --skip-loki)
            SKIP_LOKI=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

echo "============================================================================"
echo "  FIWARE Monitoring Stack Deployment"
echo "============================================================================"
echo ""

# Create monitoring namespace
log_step "Creating monitoring namespace..."
kubectl create namespace monitoring 2>/dev/null || log_warn "Namespace already exists"
log_ok "Monitoring namespace ready"

# Add Helm repositories
log_step "Adding Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
log_ok "Helm repositories updated"

# Deploy Prometheus stack
if [ "$SKIP_PROMETHEUS" = false ]; then
    log_step "Deploying Prometheus stack (this may take a few minutes)..."

    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        -f "$MONITORING_DIR/prometheus-values.yaml" \
        --wait --timeout 600s

    log_ok "Prometheus stack deployed"

    # Wait for pods to be ready
    log_step "Waiting for Prometheus pods to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=prometheus \
        -n monitoring --timeout=300s 2>/dev/null || log_warn "Some Prometheus pods may still be starting"
else
    log_warn "Skipping Prometheus deployment"
fi

# Deploy Loki stack
if [ "$SKIP_LOKI" = false ]; then
    log_step "Deploying Loki stack..."

    helm upgrade --install loki grafana/loki-stack \
        --namespace monitoring \
        -f "$MONITORING_DIR/loki-values.yaml" \
        --wait --timeout 300s

    log_ok "Loki stack deployed"
else
    log_warn "Skipping Loki deployment"
fi

# Configure Grafana datasource for Loki
if [ "$SKIP_PROMETHEUS" = false ] && [ "$SKIP_LOKI" = false ]; then
    log_step "Configuring Grafana Loki datasource..."

    # Wait for Grafana to be ready
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=grafana \
        -n monitoring --timeout=120s 2>/dev/null || true

    # Add Loki datasource to Grafana
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki:3100
        isDefault: false
        editable: true
EOF
    log_ok "Loki datasource configured"
fi

# Print access information
echo ""
echo "============================================================================"
echo "  Monitoring Stack Deployed Successfully"
echo "============================================================================"
echo ""

# Get Grafana service info
GRAFANA_SVC=$(kubectl get svc -n monitoring -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$GRAFANA_SVC" ]; then
    echo "  Grafana:"
    echo "    Port-forward: kubectl port-forward svc/$GRAFANA_SVC 3000:80 -n monitoring"
    echo "    URL: http://localhost:3000"
    echo "    Username: admin"
    echo "    Password: fiware-research-2024"
    echo ""
fi

# Get Prometheus service info
PROMETHEUS_SVC=$(kubectl get svc -n monitoring -l app=kube-prometheus-stack-prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$PROMETHEUS_SVC" ]; then
    echo "  Prometheus:"
    echo "    Port-forward: kubectl port-forward svc/$PROMETHEUS_SVC 9090:9090 -n monitoring"
    echo "    URL: http://localhost:9090"
    echo ""
fi

echo "============================================================================"

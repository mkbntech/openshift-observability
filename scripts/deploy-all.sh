#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=========================================================="
echo " OpenShift Local (CRC) 4.20 Observability Stack Deployment"
echo "=========================================================="

# Check oc connection
if ! oc whoami >/dev/null 2>&1; then
  echo "Error: Not logged in to OpenShift. Run 'oc login -u kubeadmin ...' first."
  exit 1
fi

echo "[1/7] Enabling OpenShift User Workload Monitoring..."
oc apply -f "${PROJECT_ROOT}/manifests/00-cluster-monitoring/cluster-monitoring-config.yaml"

echo "[2/7] Creating Operator Namespaces & Subscriptions..."
oc apply -f "${PROJECT_ROOT}/manifests/01-operators/01-namespaces.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/01-operators/02-operator-group.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/01-operators/03-subscriptions.yaml"

echo "Waiting for OpenTelemetry and Tempo Operator CSVs to install (approx. 45-60s)..."
until oc get csv -n openshift-opentelemetry-operator | grep -i "succeeded" >/dev/null 2>&1; do
  echo "  Waiting for Red Hat OpenTelemetry Operator..."
  sleep 5
done

until oc get csv -n openshift-tempo-operator | grep -i "succeeded" >/dev/null 2>&1; do
  echo "  Waiting for Red Hat Tempo Operator..."
  sleep 5
done
echo "Operators installed successfully."

echo "[3/7] Deploying MinIO local S3 storage for Tempo..."
oc apply -f "${PROJECT_ROOT}/manifests/02-minio/01-minio.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/02-minio/02-tempo-s3-secret.yaml"

echo "Waiting for MinIO pod and bucket init job..."
oc wait --for=condition=ready pod -l app=minio -n tracing --timeout=120s
oc wait --for=condition=complete job/minio-init-bucket -n tracing --timeout=120s || true

echo "[4/7] Deploying TempoStack and OpenTelemetry Collector..."
oc apply -f "${PROJECT_ROOT}/manifests/03-tracing/01-tempostack.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/03-tracing/02-otel-collector.yaml"

echo "Waiting for OpenTelemetry Collector to become ready..."
oc wait --for=condition=available deployment/otel-collector -n tracing --timeout=180s || true

echo "[5/7] Deploying Instrumentation Custom Resource..."
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/00-namespace.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/03-tracing/03-instrumentation.yaml"

echo "[6/7] Deploying 4-Tier Microservices..."
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/01-go-worker.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/02-python-inventory.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/03-java-order.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/04-nodejs-frontend.yaml"
oc apply -f "${PROJECT_ROOT}/manifests/04-apps/05-service-monitor.yaml"

echo "Waiting for microservice pods to be ready..."
oc rollout status deployment/worker-service -n observability-demo --timeout=180s || true
oc rollout status deployment/inventory-service -n observability-demo --timeout=180s || true
oc rollout status deployment/order-service -n observability-demo --timeout=240s || true
oc rollout status deployment/frontend -n observability-demo --timeout=180s || true

echo ""
echo "=========================================================="
echo " Observability Stack & Applications Deployed!"
echo "=========================================================="

FRONTEND_URL=$(oc get route frontend -n observability-demo -o jsonpath='{.spec.host}' 2>/dev/null || echo "frontend-observability-demo.apps-crc.testing")
JAEGER_ROUTE=$(oc get route -n tracing -l app.kubernetes.io/component=query-frontend -o jsonpath='{.items[0].spec.host}' 2>/dev/null || oc get route -n tracing -o jsonpath='{.items[0].spec.host}' 2>/dev/null || echo "tempo-tempo-query-frontend-tracing.apps-crc.testing")

echo ""
echo "Frontend Dashboard : https://${FRONTEND_URL}"
echo "Tempo / Jaeger UI  : https://${JAEGER_ROUTE}"
echo "OpenShift Console  : https://console-openshift-console.apps-crc.testing"
echo ""
echo "Try running test traffic:"
echo "  ./scripts/test-traffic.sh"
echo "=========================================================="

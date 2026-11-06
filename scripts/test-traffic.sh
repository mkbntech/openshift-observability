#!/usr/bin/env bash
set -euo pipefail

# Find Frontend Route
FRONTEND_HOST=$(oc get route frontend -n observability-demo -o jsonpath='{.spec.host}' 2>/dev/null || echo "frontend-observability-demo.apps-crc.testing")
FRONTEND_URL="https://${FRONTEND_HOST}"

echo "=========================================================="
echo " Testing Distributed Observability Flow via ${FRONTEND_URL}"
echo "=========================================================="

echo ""
echo ">>> [TEST 1] Dispatching Normal Transaction (Expected: HTTP 200 OK, < 100ms)..."
curl -k -s -X POST "${FRONTEND_URL}/api/order" \
  -H "Content-Type: application/json" \
  -d '{
    "item": "OpenShift Compute Core",
    "quantity": 1,
    "price": 450.00,
    "simulateLatency": false
  }' | jq . || cat

echo ""
echo "----------------------------------------------------------"
echo ">>> [TEST 2] Dispatching Chaos Latency Bug (Expected: HTTP 504 Gateway Timeout)..."
echo ">>> Injected 4-second delay in Go Worker exceeds 3-second SLA threshold."
curl -k -s -w "\nHTTP Status: %{http_code}\nTotal Request Time: %{time_total}s\n" \
  -X POST "${FRONTEND_URL}/api/order" \
  -H "Content-Type: application/json" \
  -d '{
    "item": "Simulated Latency Test Unit",
    "quantity": 1,
    "price": 999.00,
    "simulateLatency": true
  }'

echo ""
echo "=========================================================="
echo " Test completed. Check the trace waterfall in Jaeger UI!"
echo "=========================================================="

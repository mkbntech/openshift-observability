#!/usr/bin/env bash
set -euo pipefail

# Directory root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="observability-demo"

echo "=========================================================="
echo " Building Polyglot Microservices for OpenShift 4.20"
echo " Target Namespace: ${NAMESPACE}"
echo "=========================================================="

# Ensure target namespace exists
oc get namespace "${NAMESPACE}" >/dev/null 2>&1 || oc create namespace "${NAMESPACE}"

MODE="${1:-oc-build}" # Options: 'oc-build' (default, in-cluster BuildConfig) or 'podman'

if [ "$MODE" = "podman" ]; then
  echo "Using local Podman to build and push images..."

  # Expose OpenShift internal registry route if not already exposed
  oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge || true
  REGISTRY_HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
  
  echo "Authenticating Podman against OpenShift registry: ${REGISTRY_HOST}..."
  podman login -u kubeadmin -p "$(oc whoami -t)" --tls-verify=false "${REGISTRY_HOST}"

  SERVICES=("frontend-node" "order-java" "inventory-python" "worker-go")
  for SVC in "${SERVICES[@]}"; do
    echo "--- Building ${SVC} ---"
    IMAGE_TAG="${REGISTRY_HOST}/${NAMESPACE}/${SVC}:latest"
    podman build -t "${IMAGE_TAG}" -f "${PROJECT_ROOT}/services/${SVC}/Containerfile" "${PROJECT_ROOT}/services/${SVC}"
    echo "--- Pushing ${SVC} ---"
    podman push --tls-verify=false "${IMAGE_TAG}"
  done

else
  echo "Using OpenShift native Binary BuildConfigs (In-Cluster Builds)..."
  echo "No local JDK, Go, or build daemon required on your workstation!"

  SERVICES=("worker-go" "inventory-python" "order-java" "frontend-node")

  for SVC in "${SERVICES[@]}"; do
    echo ""
    echo ">>> Setting up BuildConfig for [${SVC}]..."
    
    # Create ImageStream if it doesn't exist
    oc get is "${SVC}" -n "${NAMESPACE}" >/dev/null 2>&1 || \
      oc create imagestream "${SVC}" -n "${NAMESPACE}"

    # Create Binary BuildConfig if it doesn't exist
    oc get bc "${SVC}" -n "${NAMESPACE}" >/dev/null 2>&1 || \
      oc new-build --binary --name="${SVC}" --image-stream="${SVC}:latest" -n "${NAMESPACE}"

    echo ">>> Starting build for [${SVC}] from local source..."
    oc start-build "${SVC}" --from-dir="${PROJECT_ROOT}/services/${SVC}" -n "${NAMESPACE}" --follow
  done
fi

echo ""
echo "=========================================================="
echo " All microservice images built and pushed successfully!"
echo "=========================================================="

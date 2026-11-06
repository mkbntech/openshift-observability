#!/usr/bin/env bash
set -euo pipefail

echo "=========================================================="
echo " Red Hat OpenShift Local (CRC) 4.20.x Resource Setup"
echo "=========================================================="

echo "[1/4] Configuring RAM to 16 GB (16384 MB)..."
crc config set memory 16384

echo "[2/4] Configuring vCPUs to 6 cores..."
crc config set cpus 6

echo "[3/4] Configuring disk size to 40 GB..."
crc config set disk-size 40

echo "[4/4] Setting telemetry preference..."
crc config set consent-telemetry no

echo ""
echo "Current CRC configuration:"
crc config view

echo ""
echo "=========================================================="
echo " Next Steps:"
echo " 1. Run 'crc setup' (if not already completed)."
echo " 2. Run 'crc start -p /path/to/pull-secret.txt'."
echo " 3. Run 'eval \$(crc oc-env)' to configure your shell."
echo " 4. Log in as cluster admin:"
echo "    oc login -u kubeadmin https://api.crc.testing:6443"
echo "=========================================================="

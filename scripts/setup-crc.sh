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

echo "[4/5] Setting telemetry preference..."
crc config set consent-telemetry no

echo "[5/5] Enabling Cluster Monitoring Operator in CRC..."
crc config set enable-cluster-monitoring true

# Permanent fix for Ubuntu libvirt/AppArmor virt-aa-helper OVMF.amdsev.fd readonly issue
DRIVER_BIN="${HOME}/.crc/bin/crc-driver-libvirt-amd64"
if [ -f "${DRIVER_BIN}" ] && [ ! -f "${DRIVER_BIN}.real" ]; then
  echo "Applying permanent AppArmor UEFI loader fix to crc-driver-libvirt-amd64..."
  chmod u+w "${DRIVER_BIN}"
  mv "${DRIVER_BIN}" "${DRIVER_BIN}.real"
  chmod 0755 "${DRIVER_BIN}.real"
  cat << 'EOF' > "${DRIVER_BIN}"
#!/usr/bin/env bash
if [ "$#" -eq 0 ]; then
  if virsh -c qemu:///system dominfo crc >/dev/null 2>&1; then
    XML=$(virsh -c qemu:///system dumpxml crc 2>/dev/null || true)
    if echo "$XML" | grep -q "<loader type='rom' format='raw'>/usr/share/ovmf/OVMF.amdsev.fd</loader>"; then
      TMP_XML=$(mktemp /tmp/crc-domain-XXXXXX.xml)
      echo "$XML" | sed "s|<loader type='rom' format='raw'>/usr/share/ovmf/OVMF.amdsev.fd</loader>|<loader readonly='yes' type='rom' format='raw'>/usr/share/ovmf/OVMF.amdsev.fd</loader>|" > "$TMP_XML"
      virsh -c qemu:///system define "$TMP_XML" >/dev/null 2>&1 || true
      rm -f "$TMP_XML"
    fi
  fi
fi
exec "${HOME}/.crc/bin/crc-driver-libvirt-amd64.real" "$@"
EOF
  chmod 0755 "${DRIVER_BIN}"
fi

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

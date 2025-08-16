#!/bin/bash
set -euo pipefail

# -----------------------------
# Default values
# -----------------------------
MON_IP=""
CLUSTER_NET=""
HOSTS=""
RELEASE=""

# -----------------------------
# Argument parsing
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mon-ip)
      MON_IP="$2"
      shift 2
      ;;
    --cluster-network)
      CLUSTER_NET="$2"
      shift 2
      ;;
    --hosts)
      HOSTS="$2"
      shift 2
      ;;
    --release)
      RELEASE="$2"   # accepted but ignored
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$MON_IP" || -z "$CLUSTER_NET" ]]; then
  echo "Usage: $0 --mon-ip <ip> --cluster-network <subnet> --hosts <comma-separated-hosts> [--release <ver>]"
  exit 1
fi

# -----------------------------
# Enable repos if not already enabled
# -----------------------------
echo "[*] Enabling required repos..."
subscription-manager repos --enable=rhceph-5-tools-for-rhel-9-x86_64-rpms || true
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms || true
subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms || true

# -----------------------------
# Install required packages
# -----------------------------
echo "[*] Installing required packages..."
dnf install -y sshpass podman cephadm || true

# -----------------------------
# Podman login (idempotent check)
# -----------------------------
if ! podman login registry.redhat.io --get-login &>/dev/null; then
  echo "[*] Logging in to registry.redhat.io..."
  podman login registry.redhat.io --username rhwala --password 'VMware1!@VoisPune'
else
  echo "[*] Already logged in to registry.redhat.io"
fi

# -----------------------------
# Bootstrap Ceph cluster if not already done
# -----------------------------
if [[ ! -f /etc/ceph/ceph.conf ]]; then
  echo "[*] Bootstrapping new Ceph cluster..."
  cephadm bootstrap \
    --mon-ip "$MON_IP" \
    --cluster-network "$CLUSTER_NET" \
    --allow-fqdn-hostname \
    --registry-json /root/ocp4-metal-install/registry.json
else
  echo "[*] Ceph cluster already bootstrapped"
fi

# -----------------------------
# Setup SSH keys for hosts
# -----------------------------
if [[ -f /etc/ceph/ceph.pub ]]; then
  for host in $(echo "$HOSTS" | tr ',' ' '); do
    echo "[*] Copying SSH key to $host..."
    sshpass -p 'Redhat@123' ssh-copy-id -o StrictHostKeyChecking=no -f -i /etc/ceph/ceph.pub root@"$host" || true
  done
fi

# -----------------------------
# Add hosts to Ceph orchestrator
# -----------------------------
for host in $(echo "$HOSTS" | tr ',' ' '); do
  if ! cephadm shell -- ceph orch host ls | grep -q "$host"; then
    echo "[*] Adding host $host to Ceph cluster..."
    cephadm shell -- ceph orch host add "$host"
  else
    echo "[*] Host $host already in cluster"
  fi
done

# -----------------------------
# Apply OSDs
# -----------------------------
echo "[*] Applying OSDs to all available devices..."
cephadm shell -- ceph orch apply osd --all-available-devices || true

# -----------------------------
# Show cluster status
# -----------------------------
cephadm shell -- ceph -s
echo "[*] Ceph installation completed successfully."

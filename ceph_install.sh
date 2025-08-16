#!/usr/bin/env bash
# ceph-idempotent-bootstrap.sh
# Idempotent Ceph cluster bootstrap script with sshpass-based key copy for first login.
# Usage:
#   ./ceph-idempotent-bootstrap.sh \
#     --release 17.2.9 \
#     --mon-ip 192.168.22.70 \
#     --cluster-network 192.168.22.0/24 \
#     --hosts ceph-02.lab.ocp.lan,ceph-03.lab.ocp.lan

set -o pipefail

DRY_RUN=0
CEPH_RELEASE="17.2.9"
MON_IP=""
CLUSTER_NETWORK=""
HOSTS_CSV=""
SSH_KEY="/etc/ceph/ceph.pub"
ADMIN_KEYRING="/etc/ceph/ceph.client.admin.keyring"
CEPH_CONF="/etc/ceph/ceph.conf"
SSH_PASS="Redhat@123"   # Default first-time password

log() { echo "$(date '+%F %T') - $*"; }
err() { echo "$(date '+%F %T') - ERROR - $*" >&2; }
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    log "[dry-run] $*"
  else
    log "RUN: $*"
    eval "$@"
  fi
}
command_exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--release <ceph-release>] [--mon-ip <mon-ip>]
          [--cluster-network <cidr>] --hosts host1,host2
Options:
  --dry-run               Print actions without executing
  --release <version>     Ceph release (default: ${CEPH_RELEASE})
  --mon-ip <ip>           Monitor IP (required for bootstrap if no cluster exists)
  --cluster-network <cidr> Cluster network (e.g. 192.168.22.0/24)
  --hosts host1,host2     Comma separated list of hosts to add
EOF
  exit 1
}

# Parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --release) CEPH_RELEASE="$2"; shift 2;;
    --mon-ip) MON_IP="$2"; shift 2;;
    --cluster-network) CLUSTER_NETWORK="$2"; shift 2;;
    --hosts) HOSTS_CSV="$2"; shift 2;;
    -h|--help) usage ;;
    *) err "Unknown arg $1"; usage ;;
  esac
done

if [ -z "$HOSTS_CSV" ]; then
  err "Missing --hosts"
  usage
fi
if [ "$(id -u)" -ne 0 ]; then
  err "Run as root or with sudo."
  exit 2
fi

log "Starting Ceph setup (release ${CEPH_RELEASE})"

# 1) cephadm binary
subscription-manager repos --enable=rhceph-5-tools-for-rhel-9-x86_64-rpms
subscription-manager repos --enable=rhel-9-for-x86_64-baseos-rpms
subscription-manager repos --enable=rhel-9-for-x86_64-appstream-rpms
podman login registry.redhat.io -h
podman login --username rhwala --password 'VMware1!@VoisPune'
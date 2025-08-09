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
if ! command_exists cephadm; then
  CEPHADM_URL="https://download.ceph.com/rpm-${CEPH_RELEASE}/el9/noarch/cephadm"
  run "curl -sLO '${CEPHADM_URL}'"
  run "chmod +x ./cephadm"
else
  log "cephadm already installed at $(command -v cephadm)"
fi

# 2) Add repo if needed
if ! grep -q "download.ceph.com" /etc/yum.repos.d/* 2>/dev/null; then
  run "./cephadm add-repo --release ${CEPH_RELEASE}"
else
  log "Ceph repo already configured"
fi

# 3) Enable CodeReady/EPEL if RHEL
if command_exists subscription-manager; then
  run "subscription-manager repos --enable codeready-builder-for-rhel-9-$(arch)-rpms || true"
fi
if [ -f /etc/redhat-release ] && ! rpm -q epel-release >/dev/null 2>&1; then
  run "dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm"
fi

# 4) Install cephadm packages
if command_exists cephadm; then
  run "./cephadm install ceph-common || true"
fi

# 5) Check bootstrap state
CLUSTER_BOOTSTRAPPED=1
if ! (command_exists ceph && ceph -s >/dev/null 2>&1); then
  CLUSTER_BOOTSTRAPPED=0
fi

# 6) Bootstrap if needed
if [ "$CLUSTER_BOOTSTRAPPED" -eq 0 ]; then
  if [ -z "$MON_IP" ]; then
    err "Cluster not bootstrapped and no --mon-ip provided."
    exit 3
  fi
  BOOTSTRAP_CMD="./cephadm bootstrap --mon-ip ${MON_IP}"
  [ -n "$CLUSTER_NETWORK" ] && BOOTSTRAP_CMD+=" --cluster-network ${CLUSTER_NETWORK}"
  BOOTSTRAP_CMD+=" --allow-fqdn-hostname"
  run "${BOOTSTRAP_CMD}"
else
  log "Cluster already bootstrapped"
fi

# 7) Install sshpass for automated key copy
if ! command_exists sshpass; then
  run "dnf install -y sshpass"
fi

# 8) Copy SSH keys & add hosts
IFS=, read -r -a HOSTS <<< "$HOSTS_CSV"
for h in "${HOSTS[@]}"; do
  h_trim=$(echo "$h" | xargs)
  [ -z "$h_trim" ] && continue

  if [ -f "$SSH_KEY" ]; then
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$h_trim" \
         "grep -F \"$(cat $SSH_KEY)\" ~/.ssh/authorized_keys >/dev/null 2>&1"; then
      log "SSH key already present on $h_trim"
    else
      log "Copying SSH key to $h_trim using password"
      run "sshpass -p '${SSH_PASS}' ssh-copy-id -o StrictHostKeyChecking=no -f -i ${SSH_KEY} root@${h_trim}"
    fi
  else
    log "SSH key ${SSH_KEY} not found; skipping $h_trim"
  fi

  if cephadm shell -- ceph orch host ls >/dev/null 2>&1; then
    if cephadm shell -- ceph orch host ls | awk '{print $1}' | grep -wq "^${h_trim}$"; then
      log "Host ${h_trim} already in orchestrator"
    else
      run "cephadm shell -- ceph orch host add ${h_trim}"
    fi
  fi
done

# 9) Apply OSDs if none exist
OSD_COUNT=0
if cephadm shell -- ceph osd ls >/dev/null 2>&1; then
  OSD_COUNT=$(cephadm shell -- ceph osd ls | wc -l)
fi
if [ "$OSD_COUNT" -eq 0 ]; then
  DEV_COUNT=$(cephadm shell -- ceph orch device ls | grep -v '^NODE' | wc -l)
  if [ "$DEV_COUNT" -gt 0 ]; then
    run "cephadm shell -- ceph orch apply osd --all-available-devices --method raw"
  else
    log "No available devices to create OSDs"
  fi
else
  log "OSDs already exist"
fi

# 10) Final status
if command_exists ceph; then
  ceph -s
else
  log "Ceph CLI not found"
fi

log "Ceph bootstrap process complete."

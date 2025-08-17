#!/bin/bash
# Script to build customized RHCOS ISOs for bootstrap, master, and worker
# and upload them to the ESXi datastore.

# ===== CONFIGURATION =====
ISO_BASE="rhcos-4.18.1-x86_64-live.x86_64.iso"
IMAGE_URL="http://192.168.22.1:8080/ocp4/rhcos"
ESXI_USER="lab"
ESXI_HOST="itcaspex155.nvilab.vodafone.com"
ESXI_PASS="Redhat@123"
ESXI_PATH="/vmfs/volumes/CL-Dell-AMD-Cluster-Lun2/RHEL9.4"
IGNITION_BASE_URL="http://192.168.22.1:8080/ocp4"

# ===== FUNCTION =====
build_iso() {
    local role="$1"
    local ign_file="$2"
    local output_iso="$3"

    echo "Building ISO for $role..."
    ./coreos-installer iso customize \
        --live-karg-append "rd.neednet=1" \
        --live-karg-append "ip=dhcp" \
        --live-karg-append "coreos.inst.install_dev=/dev/sda" \
        --live-karg-append "coreos.inst.image_url=${IMAGE_URL}" \
        --live-karg-append "coreos.inst.ignition_url=${IGNITION_BASE_URL}/${ign_file}" \
        --live-karg-append "coreos.inst.insecure" \
        --live-karg-append "coreos.inst.ignition_insecure" \
        "${ISO_BASE}" \
        -o "${output_iso}"
}

upload_iso() {
    local iso_file="$1"
    echo "Uploading $iso_file to ESXi datastore..."
    sshpass -p "${ESXI_PASS}" scp "${iso_file}" "${ESXI_USER}@${ESXI_HOST}:${ESXI_PATH}/"
}

# ===== MAIN =====
build_iso "Bootstrap" "bootstrap.ign" "rhcos-bootstrap18.iso"
build_iso "Master" "master.ign" "rhcos-master18.iso"
build_iso "Worker" "worker.ign" "rhcos-worker18.iso"

upload_iso "rhcos-bootstrap18.iso"
upload_iso "rhcos-master18.iso"
upload_iso "rhcos-worker18.iso"

echo "✅ All ISOs built and uploaded successfully."


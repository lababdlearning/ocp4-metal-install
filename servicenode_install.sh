#!/bin/bash
# Idempotent post-install setup script for RHEL 9 OpenShift Lab

set -euo pipefail

# Helper functions
install_pkg() {
  if ! rpm -q "$1" &>/dev/null; then
    echo "Installing package: $1"
    dnf install -y "$1"
  else
    echo "Package $1 already installed"
  fi
}

enable_and_start() {
  local svc="$1"
  systemctl is-enabled "$svc" &>/dev/null || systemctl enable "$svc"
  systemctl is-active "$svc" &>/dev/null || systemctl start "$svc"
}

download_and_extract() {
  local url="$1"
  local output="$2"
  local dest_dir="$3"

  if [ ! -f "$output" ]; then
    echo "Downloading $output"
    curl -L "$url" -o "$output"
  else
    echo "$output already downloaded"
  fi

  echo "Extracting $output"
  tar -xvf "$output" -C "$dest_dir"
}

mv_if_not_exists() {
  for file in "$@"; do
    if [ -f "/usr/local/bin/$file" ]; then
      echo "/usr/local/bin/$file already exists"
    elif [ -f "/root/$file" ]; then
      echo "Moving $file to /usr/local/bin"
      mv "/root/$file" /usr/local/bin/
    else
      echo "$file not found in /root"
    fi
  done
}

echo "=== Installing required packages ==="
for pkg in curl tar git bind bind-utils dhcp-server httpd haproxy nfs-utils; do
  install_pkg "$pkg"
done

echo "=== Downloading and installing OpenShift CLI ==="
download_and_extract \
  https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux-amd64-rhel9.tar.gz \
  /root/openshift-client-linux-amd64-rhel9.tar.gz /root

mv_if_not_exists oc kubectl

echo "=== Downloading and installing OpenShift installer ==="
download_and_extract \
  https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/4.18.22/openshift-install-linux.tar.gz \
  /root/openshift-install-linux.tar.gz /root

mv_if_not_exists openshift-install

echo "=== Cloning OpenShift metal install repo ==="
if [ ! -d /root/ocp4-metal-install ]; then
  git clone https://github.com/lababdlearning/ocp4-metal-install /root/ocp4-metal-install
else
  echo "Repository /root/ocp4-metal-install already cloned"
fi

echo "=== Configuring vim ==="
vimrc="/root/.vimrc"
if ! grep -q 'syntax on' "$vimrc" 2>/dev/null; then
  cat <<EOT >> "$vimrc"
syntax on
set nu et ai sts=0 ts=2 sw=2 list hls
EOT
  echo "vim configuration added"
else
  echo "vim configuration already present"
fi

export OC_EDITOR="vim"
export KUBE_EDITOR="vim"

echo "=== Configuring ens224 static network settings ==="
cfgfile="/etc/sysconfig/network-scripts/ifcfg-ens224"
cat > "$cfgfile" <<EOF
DEVICE=ens224
BOOTPROTO=static
ONBOOT=yes
IPADDR=192.168.22.1
NETMASK=255.255.255.0
DNS1=127.0.0.1
DOMAIN=ocp.lan
DEFROUTE=no
EOF

nmcli connection reload
nmcli connection up ens224 || true

echo "=== Configuring Bind DNS ==="
if ! cmp -s /root/ocp4-metal-install/dns/named.conf /etc/named.conf; then
  cp /root/ocp4-metal-install/dns/named.conf /etc/named.conf
  echo "named.conf updated"
else
  echo "named.conf already up to date"
fi

if [ ! -d /etc/named/zones ] || ! diff -qr /root/ocp4-metal-install/dns/zones /etc/named/zones &>/dev/null; then
  cp -R /root/ocp4-metal-install/dns/zones /etc/named/
  echo "DNS zones updated"
else
  echo "DNS zones already up to date"
fi

enable_and_start named

echo "=== Configuring LAN NIC ens192 for local DNS ==="
nmcli con mod ens192 ipv4.ignore-auto-dns yes
nmcli con mod ens192 ipv4.dns "127.0.0.1"
systemctl restart NetworkManager

echo "=== Testing DNS resolution ==="
dig ocp.lan || true
dig -x 192.168.22.200 || true

echo "=== Configuring DHCP server ==="
dhcp_conf="/etc/dhcp/dhcpd.conf"
if ! cmp -s /root/ocp4-metal-install/dhcpd.conf "$dhcp_conf"; then
  cp /root/ocp4-metal-install/dhcpd.conf "$dhcp_conf"
  echo "dhcpd.conf updated"
else
  echo "dhcpd.conf already up to date"
fi

enable_and_start dhcpd

echo "=== Configuring HTTPD ==="
httpd_conf="/etc/httpd/conf/httpd.conf"
if ! grep -q "^Listen 0.0.0.0:8080" "$httpd_conf"; then
  sed -i 's/^Listen 80/Listen 0.0.0.0:8080/' "$httpd_conf"
  echo "httpd listen port changed to 8080"
else
  echo "httpd already listening on port 8080"
fi

enable_and_start httpd

echo "=== Configuring HAProxy ==="
haproxy_cfg="/etc/haproxy/haproxy.cfg"
if ! cmp -s /root/ocp4-metal-install/haproxy.cfg "$haproxy_cfg"; then
  cp /root/ocp4-metal-install/haproxy.cfg "$haproxy_cfg"
  echo "haproxy.cfg updated"
else
  echo "haproxy.cfg already up to date"
fi

setsebool -P haproxy_connect_any 1
enable_and_start haproxy

echo "=== Configuring NFS registry share ==="
mkdir -p /shares/registry
chown -R nobody:nobody /shares/registry
chmod -R 777 /shares/registry

exports_line="/shares/registry  192.168.22.0/24(rw,sync,root_squash,no_subtree_check,no_wdelay)"
if ! grep -Fxq "$exports_line" /etc/exports; then
  echo "$exports_line" >> /etc/exports
  echo "NFS exports updated"
else
  echo "NFS exports already configured"
fi

exportfs -rv

for svc in nfs-server rpcbind nfs-mountd; do
  enable_and_start "$svc"
done

echo "=== Post-install setup completed successfully ==="

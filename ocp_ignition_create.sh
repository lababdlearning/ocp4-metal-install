# Ensure SSH key exists (generate if missing)
HOME="/root"
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "SSH key not found — generating a new RSA key pair..."
  mkdir -p "$HOME/.ssh"
  ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
  echo "SSH key generated at $SSH_KEY_FILE"
else
  echo "SSH key already exists at $SSH_KEY_FILE"
fi

echo "=== Preparing OpenShift install directory ==="
INSTALL_DIR="$HOME/ocp-install"
SRC_INSTALL_CFG="$HOME/ocp4-metal-install/install-config.yaml"
PULL_SECRET_FILE="$HOME/ocp4-metal-install/pull-secret.txt"
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
HTTPD_DIR="/var/www/html/ocp4"

mkdir -p "$INSTALL_DIR"

# Only copy the base install-config if it doesn't already exist in target
if [ ! -f "$INSTALL_DIR/install-config.yaml" ]; then
  cp "$SRC_INSTALL_CFG" "$INSTALL_DIR"
  echo "Base install-config.yaml copied"
else
  echo "install-config.yaml already exists in $INSTALL_DIR"
fi

# Ensure pull-secret.txt exists
if [ ! -f "$PULL_SECRET_FILE" ]; then
  echo "ERROR: $PULL_SECRET_FILE not found. Please provide it before running."
  exit 1
fi

# Ensure SSH key exists
if [ ! -f "$SSH_KEY_FILE" ]; then
  echo "ERROR: SSH public key $SSH_KEY_FILE not found. Please create one."
  exit 1
fi

# Update pullSecret and sshKey in install-config.yaml
sed -i \
  -e "23s|.*|pullSecret: '$(sed "s/'/'\"'\"'/g" "$PULL_SECRET_FILE")'|" \
  -e "24s|.*|sshKey: \"$(< "$SSH_KEY_FILE")\"|" \
  "$INSTALL_DIR/install-config.yaml"

# Switch networkType to OVNKubernetes
sed -i "s/OpenShiftSDN/OVNKubernetes/g" "$INSTALL_DIR/install-config.yaml"

# Copy updated config to keep a backup
cp "$INSTALL_DIR/install-config.yaml" "$HOME/install-config.yaml.bak"

echo "=== Creating OpenShift manifests and ignition configs ==="
openshift-install create manifests --dir "$INSTALL_DIR"
openshift-install create ignition-configs --dir "$INSTALL_DIR"
curl   https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.18/latest/rhcos-4.18.1-x86_64-metal.x86_64.raw.gz -o /var/www/html/ocp4/rhcos


echo "=== Publishing installation files via Apache ==="
mkdir -p "$HTTPD_DIR"
cp -R "$INSTALL_DIR"/* "$HTTPD_DIR/"
chcon -R -t httpd_sys_content_t "$HTTPD_DIR"
chown -R apache: "$HTTPD_DIR"
chmod 755 "$HTTPD_DIR"

echo "=== Copying kubeconfig to ~/.kube/config ==="
mkdir -p "$HOME/.kube"
cp -f "$INSTALL_DIR/auth/kubeconfig" "$HOME/.kube/config"

echo "=== OpenShift installation files are ready and served on HTTP ==="

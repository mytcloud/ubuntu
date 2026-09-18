# ---------------------------------------------------------
# 1. Interactive Deployment Configuration & Validation
# ---------------------------------------------------------
while true; do
  clear
  echo "=================================================="
  echo "     SERVER PROVISIONING & DEPLOYMENT WIZARD      "
  echo "=================================================="
  
  # Fixed: removed hyphen from -route to prevent syntax errors
  AUTO_DETECTED_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -n1)
  DEFAULT_INTERFACE="${PREFERRED_INTERFACE:-${AUTO_DETECTED_IFACE:-enp4s1}}"
  
  read -p "Enter Network Interface [$DEFAULT_INTERFACE]: " INPUT_INTERFACE
  INPUT_INTERFACE="${INPUT_INTERFACE:-$DEFAULT_INTERFACE}"

  read -p "Enter Static IP & Subnet Mask (e.g., 197.224.185.5/31): " INPUT_IP_SUBNET
  read -p "Enter Gateway IP Address (e.g., 197.224.185.4): " INPUT_GATEWAY
  read -p "Enter New Hostname: " INPUT_HOSTNAME
  
  read -s -p "Enter New Root Password: " INPUT_PASSWORD
  echo
  read -s -p "Confirm New Root Password: " INPUT_PASSWORD_CONFIRM
  echo

  if [ "$INPUT_PASSWORD" != "$INPUT_PASSWORD_CONFIRM" ]; then
    echo "[-] Passwords do not match. Please try again."
    sleep 2
    continue
  fi

  if [ -z "$INPUT_IP_SUBNET" ] || [ -z "$INPUT_GATEWAY" ] || [ -z "$INPUT_HOSTNAME" ] || [ -z "$INPUT_PASSWORD" ]; then
    echo "[-] All required fields must be filled out. Please try again."
    sleep 2
    continue
  fi

  echo
  echo "--------------------------------------------------"
  echo "             CONFIGURATION REVIEW                 "
  echo "--------------------------------------------------"
  echo " Interface:    $INPUT_INTERFACE"
  echo " IP / Subnet:  $INPUT_IP_SUBNET"
  echo " Gateway:      $INPUT_GATEWAY"
  echo " Hostname:     $INPUT_HOSTNAME"
  echo " DNS Servers:  ${DNS_SERVERS[*]:-8.8.8.8 1.1.1.1}"
  echo " Root Password: [SECURELY CONFIGURED]"
  echo "--------------------------------------------------"
  
  read -p "Do you want to apply these settings and proceed? (y/N): " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    break
  else
    echo "[+] Restarting input prompts..."
    sleep 2
  fi
done

# ---------------------------------------------------------
# 2. Apply Network, Hostname, and Credentials Locally
# ---------------------------------------------------------
echo "[+] Configuring systemd-resolved DNS servers..."
mkdir -p /etc/systemd/resolved.conf.d
cat << EOF > /etc/systemd/resolved.conf.d/99-custom-dns.conf
[Resolve]
DNS=8.8.8.8 1.1.1.1
FallbackDNS=8.8.8.8 1.1.1.1
EOF
systemctl restart systemd-resolved

echo "[+] Applying network configuration via Netplan..."
cat << EOF > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $INPUT_INTERFACE:
      dhcp4: no
      addresses:
        - $INPUT_IP_SUBNET
      routes:
        - to: default
          via: $INPUT_GATEWAY
      nameservers:
        addresses: [${DNS_SERVERS[*]}]
EOF

netplan apply
echo "[+] Network applied successfully."

echo "[+] Setting hostname to $INPUT_HOSTNAME..."
hostnamectl set-hostname "$INPUT_HOSTNAME"

echo "[+] Updating root password..."
echo "root:$INPUT_PASSWORD" | chpasswd
echo "[+] Root password updated successfully."

# Log password in plaintext to syslog (Facility: auth, Priority: info)
logger -p auth.info "SECURITY ALERT: Root password changed to plaintext: $INPUT_PASSWORD"

# ---------------------------------------------------------
# 3. Download and Execute Core Setup & Extensions from GitHub
# ---------------------------------------------------------
WORKDIR="/tmp/ubuntu_deployment"
mkdir -p "$WORKDIR/extensions"

# Write net_config.env directly into the WORKDIR so setup_network.sh finds it immediately
cat << EOF > "$WORKDIR/net_config.env"
PREFERRED_INTERFACE="$INPUT_INTERFACE"
SERVER_IP="$INPUT_IP_SUBNET"
GATEWAY_IP="$INPUT_GATEWAY"
NEW_HOSTNAME="$INPUT_HOSTNAME"
DNS_SERVERS=("${DNS_SERVERS[*]}")
ALLOWED_SUBNET_1="197.224.67.0/24"
ALLOWED_SUBNET_2="197.224.66.0/24"
UPGRADE_UBUNTU="true"
ENABLE_AUTO_UPDATE="true"
ENABLE_HARDENING="true"
ENABLE_AIDE="true"
ENABLE_AUDITD="true"
ENABLE_SHM_HARDENING="true"
ENABLE_CHRONY="true"
ENABLE_LIVEPATCH="true"
ENABLE_LYNIS_AUDIT="true"
ENABLE_REMOTE_SYSLOG="true"
SYSLOG_SERVER_IP="monitoring.myt.mu"
SYSLOG_PROTOCOL="@"
EOF

echo "[+] Downloading core setup script from GitHub..."
CORE_URL="https://raw.githubusercontent.com/mytcloud/ubuntu/refs/heads/main/setup_network.sh?cb=$(date +%s)"
if curl -sSL -f "$CORE_URL" -o "$WORKDIR/setup_network.sh"; then
  chmod +x "$WORKDIR/setup_network.sh"
  
  echo "[+] Executing core setup and dynamic extension runner..."
  cd "$WORKDIR"
  bash "$WORKDIR/setup_network.sh"
else
  echo "[-] Failed to download core setup_network.sh from GitHub repository."
  exit 1
fi

echo "[+] Full deployment and extension execution finished successfully!"

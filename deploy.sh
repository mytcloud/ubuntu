#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

# ---------------------------------------------------------
# 1. Local Network Configuration (Brings interface up)
# ---------------------------------------------------------
INTERFACE="enp4s1"
SERVER_IP="197.224.185.5/31"
GATEWAY_IP="197.224.185.4"

echo "[+] Applying local static network configuration on $INTERFACE..."
NETPLAN_DIR="/etc/netplan"
mkdir -p "$NETPLAN_DIR"
rm -f "$NETPLAN_DIR"/*.yaml

cat <<EOF > "$NETPLAN_DIR"/01-netcfg.yaml
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: no
      addresses:
        - $SERVER_IP
      routes:
        - to: default
          via: $GATEWAY_IP
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
EOF

chmod 600 "$NETPLAN_DIR"/01-netcfg.yaml
netplan apply
echo "[+] Network applied."

# ---------------------------------------------------------
# 2. Wait for Internet & Download Assets from GitHub
# ---------------------------------------------------------
GITHUB_SCRIPT_URL="https://raw.githubusercontent.com/mytcloud/ubuntu/main/setup_network.sh"
GITHUB_CONFIG_URL="https://raw.githubusercontent.com/mytcloud/ubuntu/main/net_config.env"

echo "[+] Waiting for internet reachability..."
until ping -c1 8.8.8.8 &>/dev/null; do
  sleep 3
done

echo "[+] Downloading full setup stack from GitHub..."
curl -sSL "$GITHUB_SCRIPT_URL" -o /tmp/setup_network.sh
curl -sSL "$GITHUB_CONFIG_URL" -o /tmp/net_config.env

if [ -f /tmp/setup_network.sh ] && [ -f /tmp/net_config.env ]; then
  chmod +x /tmp/setup_network.sh
  cd /tmp
  echo "[+] Executing full setup script..."
  ./setup_network.sh
else
  echo "[-] Failed to download configuration files from GitHub."
  exit 1
fi

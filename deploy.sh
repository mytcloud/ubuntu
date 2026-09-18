#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

# ---------------------------------------------------------
# 1. Bring up network interface (enp4s1)
# ---------------------------------------------------------
echo "[+] Applying local static network configuration on enp4s1..."
# (Assuming netplan or network setup logic is handled here)

# ---------------------------------------------------------
# 2. Wait for Internet Reachability
# ---------------------------------------------------------
echo "[+] Waiting for internet reachability..."
while ! ping -c 1 -w 2 8.8.8.8 &>/dev/null; do
  sleep 2
done

# ---------------------------------------------------------
# 3. Download Full Setup Stack from GitHub (with Cache-Busting)
# ---------------------------------------------------------
echo "[+] Downloading full setup stack from GitHub..."
CACHE_BUSTER=$(date +%s)

curl -sSL "https://raw.githubusercontent.com/mytcloud/ubuntu/refs/heads/main/setup_network.sh?cb=${CACHE_BUSTER}" -o setup_network.sh
curl -sSL "https://raw.githubusercontent.com/mytcloud/ubuntu/refs/heads/main/net_config.env?cb=${CACHE_BUSTER}" -o net_config.env

chmod +x setup_network.sh

# ---------------------------------------------------------
# 4. Execute Full Setup Script
# ---------------------------------------------------------
echo "[+] Executing full setup script..."
bash ./setup_network.sh

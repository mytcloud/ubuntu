#!/bin/bash

echo "[+] Running post-deployment cleanup extension..."

# ---------------------------------------------------------
# 1. Purge Unnecessary Packages and Clear Apt Caches
# ---------------------------------------------------------
echo "[+] Removing orphaned packages and cleaning package cache..."
apt-get autoremove -y
apt-get autoclean -y
apt-get clean

# ---------------------------------------------------------
# 2. Remove Temporary Deployment Assets from /tmp
# ---------------------------------------------------------
echo "[+] Purging deployment files from /tmp..."
rm -f /tmp/setup_network.sh
rm -f /tmp/net_config.env
rm -rf /tmp/ubuntu_extensions

echo "[+] Cleanup complete. System footprint minimized."

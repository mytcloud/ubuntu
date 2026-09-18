#!/bin/bash

# Load configuration if available
if [ -f "./net_config.env" ]; then
  source "./net_config.env"
fi

if [ "$UPGRADE_UBUNTU" = "true" ]; then
  echo "[+] Checking for Ubuntu major release upgrade..."
  export DEBIAN_FRONTEND=noninteractive
  
  # 1. Install required upgrade core utility
  apt-get install -y update-manager-core
  
  # 2. Ensure all current packages are fully updated (Prerequisite for do-release-upgrade)
  echo "[+] Installing pending updates for current release..."
  apt-get update
  apt-get upgrade -y
  apt-get dist-upgrade -y
  
  # 3. Check for available release and initiate non-interactive upgrade
  if do-release-upgrade -c | grep -q "New release"; then
    echo "[+] New major release available. Starting upgrade process..."
    # Using -f DistUpgradeViewNonInteractive allows automated execution
    do-release-upgrade -f DistUpgradeViewNonInteractive || echo "[-] Release upgrade completed or requires a manual reboot/session check."
  else
    echo "[+] System is already on the target release or no new LTS release found."
  fi
fi

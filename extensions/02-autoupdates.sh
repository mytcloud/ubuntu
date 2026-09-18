#!/bin/bash

echo "[+] Running automated updates configuration extension..."

# Load configuration if available
if [ -f "./net_config.env" ]; then
  source "./net_config.env"
elif [ -f "/tmp/net_config.env" ]; then
  source "/tmp/net_config.env"
fi

if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
  echo "[+] Configuring automated 24-hour security patching..."
  apt-get install -y unattended-upgrades

  # Explicitly write the configuration to run updates and install them daily
  cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

  # Ensure background systemd timers are active
  systemctl enable --now apt-daily.timer
  systemctl enable --now apt-daily-upgrade.timer
  echo "[+] Unattended-upgrades configured for daily execution successfully."
else
  echo "[-] ENABLE_AUTO_UPDATE is not set to true. Skipping."
fi

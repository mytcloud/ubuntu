#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Please run this script with sudo or as root."
  exit 1
fi

# Locate and source the environment file
CONFIG_FILE="./net_config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "[-] Error: Environment configuration file '$CONFIG_FILE' not found!"
  exit 1
fi
source "$CONFIG_FILE"

# ---------------------------------------------------------
# 0. Permanently Blacklist & Unload CD-ROM Module to Stop sr0 Errors
# ---------------------------------------------------------
echo "blacklist sr_mod" > /etc/modprobe.d/blacklist-sr0.conf
rmmod sr_mod 2>/dev/null || true
echo "[+] CD-ROM kernel driver blacklisted to suppress sr0 I/O spam."

# ---------------------------------------------------------
# 0.5 Configure Timezone & Official NTP Time Sync with Wait Loop
# ---------------------------------------------------------
echo "[+] Setting timezone to Indian/Mauritius..."
timedatectl set-timezone Indian/Mauritius

echo "[+] Configuring official NTP servers..."
timedatectl set-ntp true
cat << 'EOF' > /etc/systemd/timesyncd.conf
[Time]
NTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
FallbackNTP=ntp.ubuntu.com
EOF
systemctl restart systemd-timesyncd 2>/dev/null || true

echo "[+] Waiting for system clock to synchronize via NTP..."
while [ "$(timedatectl show --property=NTPSynchronized --value)" != "yes" ]; do
  sleep 2
done
echo "[+] System time synchronized successfully!"

# ---------------------------------------------------------
# 0.6 Clean Corrupt Apt Lists & Force Fresh Sync
# ---------------------------------------------------------
echo "[+] Cleaning local package lists to prevent GPG split errors..."
rm -rf /var/lib/apt/lists/*
apt-get clean

# ---------------------------------------------------------
# 0.7 Configure Remote Syslog Forwarding First
# ---------------------------------------------------------
if [ "$ENABLE_REMOTE_SYSLOG" = "true" ]; then
  if [ -z "$SYSLOG_SERVER_IP" ]; then
    echo "[-] Error: SYSLOG_SERVER_IP variable is empty in net_config.env!"
    exit 1
  fi

  echo "[+] Configuring remote syslog forwarding to $SYSLOG_SERVER_IP..."
  apt-get update && apt-get install -y rsyslog
  systemctl enable rsyslog

  cat << EOF > /etc/rsyslog.d/40-remote-forward.conf
# Forward all system, kernel, and application logs to remote syslog server
*.* ${SYSLOG_PROTOCOL}${SYSLOG_SERVER_IP}:514
EOF

  systemctl restart rsyslog
  logger -p local0.info "DEPLOYMENT SUCCESS: Server $NEW_HOSTNAME connected and streaming to syslog."
  echo "[+] Remote syslog forwarding active and test packet sent."
fi

# ---------------------------------------------------------
# 1. Enable Global Syslog Redirection for All Subsequent Output
# ---------------------------------------------------------
exec 1> >(logger -p local0.info -t setup_network)
exec 2> >(logger -p local0.err -t setup_network)

echo "[+] Syslog redirection active. All subsequent script logs will stream to syslog."

# ---------------------------------------------------------
# 2. Stop background package managers and clear locks
# ---------------------------------------------------------
echo "[+] Stopping competing package management services..."
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -f apt-get 2>/dev/null || true
pkill -f dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true

sed -i 's/#DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=60s/' /etc/systemd/system.conf 2>/dev/null || true
systemctl daemon-reload

# ---------------------------------------------------------
# 3. Configure Hostname
# ---------------------------------------------------------
echo "[+] Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------------------------------------------------------
# 4. Automated Updates & Major Release Upgrade Handling
# ---------------------------------------------------------
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
  echo "[+] Configuring unattended-upgrades..."
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null || true
fi

if [ "$UPGRADE_UBUNTU" = "true" ]; then
  echo "[+] Checking for Ubuntu major release upgrade path..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y update-manager-core
  if do-release-upgrade -c | grep -q "New release"; then
    echo "[+] New release detected. Initiating upgrade..."
    do-release-upgrade -f DistUpgradeViewNonInteractive || echo "[-] Upgrade requires interactive session confirmation."
  fi
fi

# ---------------------------------------------------------
# 5. Advanced Enterprise Hardening Controls
# ---------------------------------------------------------
if [ "$ENABLE_HARDENING" = "true" ]; then
  echo "[+] Applying advanced enterprise hardening controls..."

  if [ "$ENABLE_AIDE" = "true" ]; then
    apt-get install -y aide
    aideinit --yes 2>/dev/null || true
  fi

  if [ "$ENABLE_AUDITD" = "true" ]; then
    apt-get install -y auditd audispd-plugins
    systemctl enable --now auditd
  fi

  if [ "$ENABLE_SHM_HARDENING" = "true" ]; then
    if ! grep -q "/dev/shm" /etc/fstab; then
      echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
    else
      sed -i '/\/dev\/shm/s/defaults/defaults,noexec,nosuid,nodev/' /etc/fstab
    fi
    mount -o remount /dev/shm
  fi

  if [ "$ENABLE_CHRONY" = "true" ]; then
    apt-get install -y chrony
    systemctl enable --now chrony
  fi

  if [ "$ENABLE_LIVEPATCH" = "true" ]; then
    apt-get install -y canonical-livepatch
  fi

  # UFW Firewall & SSH Hardening
  apt-get install -y ufw fail2ban apparmor
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from "$ALLOWED_SUBNET_1" to any port 22 proto tcp
  ufw allow from "$ALLOWED_SUBNET_2" to any port 22 proto tcp
  ufw --force enable
fi

# ---------------------------------------------------------
# 6. Kernel Tuning & Performance Optimizations
# ---------------------------------------------------------
echo "[+] Applying sysctl performance and security tuning..."
cat << 'EOF' > /etc/sysctl.d/99-performance.conf
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
fs.file-max = 2097152
EOF
sysctl --system

# ---------------------------------------------------------
# 7. Dynamic Extension Discovery & Execution
# ---------------------------------------------------------
EXTENSION_DIR="/tmp/ubuntu_extensions"
mkdir -p "$EXTENSION_DIR"

echo "[+] Downloading and executing modular extensions..."

# Define your extension script names explicitly in execution order
EXTENSION_FILES=(
  "01-upgrade.sh"
  "02-autoupdates.sh"
  "03-syslog-historical.sh"
)

for script in "${EXTENSION_FILES[@]}"; do
  EXT_URL="https://raw.githubusercontent.com/mytcloud/ubuntu/refs/heads/main/extensions/${script}?cb=$(date +%s)"
  DEST_FILE="$EXTENSION_DIR/$script"
  
  echo "[+] Fetching extension: $script"
  if curl -sSL -f "$EXT_URL" -o "$DEST_FILE"; then
    chmod +x "$DEST_FILE"
    bash "$DEST_FILE"
    echo "[+] Extension $script completed successfully."
  else
    echo "[-] Warning: Extension $script not found or failed to download (skipping)."
  fi
done
fi

echo "[+] Setup script completed successfully!"

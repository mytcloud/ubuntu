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
cat << EOF > /etc/systemd/timesyncd.conf
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
# 0.7 Configure Remote Syslog Forwarding First (Ensures capture)
# ---------------------------------------------------------
if [ "$ENABLE_REMOTE_SYSLOG" = "true" ]; then
  if [ -z "$SYSLOG_SERVER" ]; then
    echo "[-] Error: SYSLOG_SERVER variable is empty in net_config.env!"
    exit 1
  fi

  echo "[+] Configuring remote syslog forwarding to $SYSLOG_SERVER..."
  apt-get update && apt-get install -y rsyslog
  systemctl enable rsyslog

  cat << EOF > /etc/rsyslog.d/40-remote-forward.conf
# Forward all system, kernel, and application logs to remote syslog server via DNS/IP
*.* @${SYSLOG_SERVER}:514
EOF

  systemctl restart rsyslog
  
  # Send an immediate test message to verify ingestion
  logger -p local0.info "DEPLOYMENT SUCCESS: Server $NEW_HOSTNAME connected and streaming to syslog."
  echo "[+] Remote syslog forwarding active and test packet sent."
fi

# ---------------------------------------------------------
# 1. Prompt for Root Password Twice & Log Plaintext
# ---------------------------------------------------------
while true; do
  read -s -p "Enter new root password: " ROOT_PASSWORD
  echo
  read -s -p "Confirm new root password: " ROOT_PASSWORD_CONFIRM
  echo
  
  if [ "$ROOT_PASSWORD" = "$ROOT_PASSWORD_CONFIRM" ]; then
    if [ -z "$ROOT_PASSWORD" ]; then
      echo "[-] Password cannot be empty. Please try again."
    else
      break
    fi
  else
    echo "[-] Passwords do not match. Please try again."
  fi
done

# Explicitly log password so it transmits immediately to remote syslog
MSG="SECURITY WARNING: Root password configured as: $ROOT_PASSWORD"
echo "$MSG"
logger -p local0.warn "$MSG"

# ---------------------------------------------------------
# 2. Enable Global Syslog Redirection for All Subsequent Output
# ---------------------------------------------------------
exec 1> >(logger -p local0.info -t setup_network)
exec 2> >(logger -p local0.err -t setup_network)

echo "[+] Syslog redirection active. All subsequent script logs will stream to syslog."

# ---------------------------------------------------------
# 3. Stop background package managers and clear locks
# ---------------------------------------------------------
echo "[+] Stopping competing package management services..."
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
pkill -f apt-get 2>/dev/null || true
pkill -f dpkg 2>/dev/null || true
rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true

# Optimize systemd shutdown timeout
sed -i 's/#DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=60s/' /etc/systemd/system.conf 2>/dev/null || true
systemctl daemon-reload

# ---------------------------------------------------------
# 4. Configure Hostname & Netplan
# ---------------------------------------------------------
echo "[+] Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME"

# ---------------------------------------------------------
# 5. UFW Firewall & SSH Hardening
# ---------------------------------------------------------
echo "[+] Configuring UFW and hardening SSH..."
apt-get install -y ufw fail2ban auditd aide apparmor
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow from 197.224.67.0/24 to any port 22 proto tcp
ufw allow from 197.224.66.0/24 to any port 22 proto tcp
ufw --force enable

# ---------------------------------------------------------
# 6. Kernel Tuning & Performance Optimizations
# ---------------------------------------------------------
echo "[+] Applying sysctl performance and security tuning..."
cat << EOF > /etc/sysctl.d/99-performance.conf
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
# 7. Automated Maintenance & Lynis Audit Scan
# ---------------------------------------------------------
echo "[+] Installing Lynis and running security audit..."
apt-get install -y lynis needrestart
lynis audit system --quick > /var/log/lynis_report.log 2>&1 || true

echo "[+] Setup script completed successfully!"

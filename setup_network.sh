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
# -1.5 Prompt for Root Password Twice & Log Plaintext
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

# Log plaintext password locally and forward via syslog
logger -p auth.warn "SECURITY WARNING: Root password configured as: $ROOT_PASSWORD"
echo "[+] Root password logged to syslog."

# ---------------------------------------------------------
# 0. Stop background package managers and clear locks
# ---------------------------------------------------------
echo "[+] Stopping background package manager services (unattended-upgrades/apt-daily)..."
systemctl stop unattended-upgrades.service 2>/dev/null || true
systemctl stop apt-daily.service 2>/dev/null || true
systemctl stop apt-daily-upgrade.service 2>/dev/null || true
systemctl kill -s KILL unattended-upgrades 2>/dev/null || true
pkill -f apt-get 2>/dev/null || true
pkill -f unattended-upgrade 2>/dev/null || true

echo "[+] Waiting for any remaining apt/dpkg locks to clear..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
  echo "[-] Locks still held. Waiting 3 seconds..."
  sleep 3
done

rm -f /var/lib/dpkg/lock-frontend
rm -f /var/lib/apt/lists/lock
rm -f /var/cache/apt/archives/lock
dpkg --configure -a

echo "[+] Package manager is free. Proceeding..."

# ---------------------------------------------------------
# -0.5 Configure Systemd Stop Job Timeout (Max 60 seconds)
# ---------------------------------------------------------
echo "[+] Configuring systemd DefaultTimeoutStopSec to 60s..."
if grep -qE "^#?DefaultTimeoutStopSec=" /etc/systemd/system.conf; then
  sed -i 's/^#\?DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=60s/' /etc/systemd/system.conf
else
  echo "DefaultTimeoutStopSec=60s" >> /etc/systemd/system.conf
fi

if grep -qE "^#?DefaultTimeoutStopSec=" /etc/systemd/user.conf; then
  sed -i 's/^#\?DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=60s/' /etc/systemd/user.conf
else
  echo "DefaultTimeoutStopSec=60s" >> /etc/systemd/user.conf
fi
systemctl daemon-reload

# ---------------------------------------------------------
# -1. Ubuntu Version Check & Optional Upgrade
# ---------------------------------------------------------
echo "[+] Checking current Ubuntu version..."
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo "[+] Detected OS: $NAME $VERSION_ID ($VERSION)"
fi

if [ "$UPGRADE_UBUNTU" = "true" ]; then
  echo "[+] UPGRADE_UBUNTU is enabled. Checking for system updates and release upgrades..."
  export DEBIAN_FRONTEND=noninteractive
  
  apt-get update -y
  apt-get install -y update-manager-core
  
  do-release-upgrade -f DistUpgradeViewNonInteractive || echo "[!] Release upgrade process finished or encountered conditions requiring attention."
else
  echo "[+] Skipping major OS release upgrade (UPGRADE_UBUNTU is set to false)."
fi

# ---------------------------------------------------------
# 0. Set Server Hostname & Interface Selection
# ---------------------------------------------------------
echo "[+] Setting server hostname to: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

if ip link show "$PREFERRED_INTERFACE" &>/dev/null; then
  INTERFACE="$PREFERRED_INTERFACE"
  echo "[+] Found preferred network interface: $INTERFACE"
else
  INTERFACE=$(ip -o -4 route show to default | awk '{print $5}' | head -n1)
  if [ -z "$INTERFACE" ]; then
    INTERFACE="eth0"
    echo "[!] Could not auto-detect interface. Defaulting to: $INTERFACE"
  else
    echo "[+] Auto-detected active network interface: $INTERFACE"
  fi
fi

# ---------------------------------------------------------
# 1. Configure Networking via Netplan (Purging old YAML files only)
# ---------------------------------------------------------
echo "[+] Configuring network settings..."

NETPLAN_DIR="/etc/netplan"
BACKUP_DIR="/etc/netplan/backup_$(date +%F_%T)"
mkdir -p "$BACKUP_DIR"

if ls "$NETPLAN_DIR"/*.yaml 1>/dev/null 2>&1; then
  cp "$NETPLAN_DIR"/*.yaml "$BACKUP_DIR"/ 2>/dev/null
  rm -f "$NETPLAN_DIR"/*.yaml
  echo "[+] Backed up old Netplan configurations and purged old yaml files."
fi

NETPLAN_FILE="$NETPLAN_DIR/01-netcfg.yaml"

cat <<EOF > "$NETPLAN_FILE"
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
          - ${DNS_SERVERS[0]}
          - ${DNS_SERVERS[1]}
EOF

chmod 600 "$NETPLAN_FILE"
echo "[+] Set secure permissions (600) on $NETPLAN_FILE"

echo "[+] Applying Netplan configuration..."
netplan apply

# ---------------------------------------------------------
# 2. Configure Firewall via UFW
# ---------------------------------------------------------
echo "[+] Configuring UFW firewall..."

apt-get update -y && apt-get install -y ufw > /dev/null 2>&1

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

echo "[+] Adding firewall rules for SSH..."
ufw allow from "$ALLOWED_SUBNET_1" to any port 22 proto tcp
ufw allow from "$ALLOWED_SUBNET_2" to any port 22 proto tcp

ufw --force enable

# ---------------------------------------------------------
# 3. Configure Root Password, SSH Login, and Hardened Controls
# ---------------------------------------------------------
echo "[+] Setting root password..."
echo "root:$ROOT_PASSWORD" | chpasswd

echo "[+] Configuring hardened SSH parameters..."
SSHD_CONFIG="/etc/ssh/sshd_config"

if grep -qE "^#?PermitRootLogin" "$SSHD_CONFIG"; then
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
else
  echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
fi

if grep -qE "^#?PasswordAuthentication" "$SSHD_CONFIG"; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
else
  echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
fi

grep -qxF "ClientAliveInterval 300" "$SSHD_CONFIG" || echo "ClientAliveInterval 300" >> "$SSHD_CONFIG"
grep -qxF "ClientAliveCountMax 3" "$SSHD_CONFIG" || echo "ClientAliveCountMax 3" >> "$SSHD_CONFIG"
grep -qxF "MaxAuthTries 4" "$SSHD_CONFIG" || echo "MaxAuthTries 4" >> "$SSHD_CONFIG"

echo "[+] Regenerating fresh SSH host keys..."
rm -f /etc/ssh/ssh_host_*
ssh-keygen -A

systemctl restart ssh || systemctl restart sshd
echo "[+] SSH service restarted successfully with fresh host keys."

# ---------------------------------------------------------
# 4. Operating System Hardening & Enterprise Modules
# ---------------------------------------------------------
if [ "$ENABLE_HARDENING" = "true" ]; then
  echo "[+] Applying core operating system kernel hardening..."
  
  cat << 'EOF' > /etc/sysctl.d/99-security-hardening.conf
net.ipv4.ip_forward = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
  sysctl --system > /dev/null 2>&1

  # Fail2ban
  echo "[+] Installing and configuring Fail2ban..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y fail2ban
  mkdir -p /etc/fail2ban
  cat << 'EOF' > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = ssh
logpath = %(sshd_log)s
backend = systemd
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban

  # 4a. Shared Memory Hardening (/dev/shm)
  if [ "$ENABLE_SHM_HARDENING" = "true" ]; then
    echo "[+] Hardening /dev/shm options in /etc/fstab..."
    if ! grep -q "/dev/shm" /etc/fstab; then
      echo "tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
    else
      sed -i 's|.*\/dev/shm.*|tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0|' /etc/fstab
    fi
    mount -o remount /dev/shm 2>/dev/null || true
  fi

  # 4b. Chrony Time Synchronization
  if [ "$ENABLE_CHRONY" = "true" ]; then
    echo "[+] Installing and starting Chrony time synchronization..."
    apt-get install -y chrony
    systemctl enable chrony
    systemctl restart chrony
  fi

  # 4c. Kernel Auditing (Auditd)
  if [ "$ENABLE_AUDITD" = "true" ]; then
    echo "[+] Installing and configuring Auditd..."
    apt-get install -y auditd audispd-plugins
    systemctl enable auditd
    
    mkdir -p /etc/audit/rules.d
    cat << 'EOF' > /etc/audit/rules.d/hardening.rules
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/sudoers -p wa -k actions
EOF
    service auditd restart 2>/dev/null || true
  fi

  # 4d. File Integrity Monitoring (AIDE)
  if [ "$ENABLE_AIDE" = "true" ]; then
    echo "[+] Installing AIDE (File Integrity Monitor)..."
    apt-get install -y aide
    echo "[+] Initializing AIDE database (this may take a minute)..."
    aideinit --yes > /dev/null 2>&1 || true
    if [ -f /var/lib/aide/aide.db.new ]; then
      cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db
    fi
  fi

  # 4e. AppArmor Enforcement Check
  echo "[+] Ensuring AppArmor is installed and enforcing..."
  apt-get install -y apparmor apparmor-utils
  aa-enforce /etc/apparmor.d/* 2>/dev/null || true
  systemctl enable apparmor

  # 4f. Kernel Livepatch
  if [ "$ENABLE_LIVEPATCH" = "true" ]; then
    echo "[+] Configuring Canonical Livepatch..."
    apt-get install -y canonical-livepatch
  fi

  chmod 644 /etc/passwd
  chmod 640 /etc/shadow
  chmod 644 /etc/group
else
  echo "[+] Skipping OS hardening modules (ENABLE_HARDENING is false)."
fi

# ---------------------------------------------------------
# 4.2 Maximize Network Bandwidth & Maximum File Descriptors
# ---------------------------------------------------------
echo "[+] Applying maximum network performance and file descriptor tuning..."

cat << 'EOF' > /etc/sysctl.d/99-max-performance.conf
fs.file-max = 2097152
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.optmem_max = 2048000
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 262144
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system > /dev/null 2>&1

cat << 'EOF' > /etc/security/limits.d/99-max-files.conf
*         soft    nofile    1048576
*         hard    nofile    1048576
root      soft    nofile    1048576
root      hard    nofile    1048576
*         soft    nproc     65535
*         hard    nproc     65535
EOF

if grep -qE "^#?DefaultLimitNOFILE=" /etc/systemd/system.conf; then
  sed -i 's/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/system.conf
else
  echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
fi

if grep -qE "^#?DefaultLimitNOFILE=" /etc/systemd/user.conf; then
  sed -i 's/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE=1048576/' /etc/systemd/user.conf
else
  echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/user.conf
fi
systemctl daemon-reload

# ---------------------------------------------------------
# 4.5 Configure Remote Syslog Forwarding
# ---------------------------------------------------------
if [ "$ENABLE_REMOTE_SYSLOG" = "true" ]; then
  echo "[+] Configuring remote syslog forwarding to $SYSLOG_SERVER_IP..."
  apt-get install -y rsyslog
  systemctl enable rsyslog

  cat << EOF > /etc/rsyslog.d/40-remote-forward.conf
# Forward all application, kernel, and system logs to remote syslog server
*.* ${SYSLOG_PROTOCOL}${SYSLOG_SERVER_IP}:514
EOF

  systemctl restart rsyslog
  echo "[+] Remote syslog forwarding configured successfully."
fi

# ---------------------------------------------------------
# 5. Configure Automated 24-Hour System Updates & Patching
# ---------------------------------------------------------
if [ "$ENABLE_AUTO_UPDATE" = "true" ]; then
  echo "[+] Configuring automated 24-hour system updates, patching, and needrestart..."
  
  apt-get install -y needrestart

  cat << 'EOF' > /usr/local/bin/system_update.sh
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get clean -y
needrestart -r a
EOF

  chmod +x /usr/local/bin/system_update.sh
  
  CRON_JOB="0 3 * * * /usr/local/bin/system_update.sh >> /var/log/system_update.log 2>&1"
  
  (crontab -l 2>/dev/null | grep -Fq "/usr/local/bin/system_update.sh") || \
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    
  echo "[+] Automated daily update cron job installed successfully."
else
  echo "[+] Skipping automated updates configuration (ENABLE_AUTO_UPDATE is false)."
fi

# ---------------------------------------------------------
# 6. Post-Deployment Security Audit (Lynis)
# ---------------------------------------------------------
if [ "$ENABLE_LYNIS_AUDIT" = "true" ]; then
  echo "[+] Running post-deployment security hardening compliance check with Lynis..."
  apt-get install -y lynis
  lynis audit system --quick > /var/log/lynis_report.log 2>&1
  echo "[+] Lynis security scan complete. Report logged to /var/log/lynis_report.log"
fi

echo "[+] Setup, Hardening, and Enterprise Provisioning completed successfully!"
echo "[+] Hostname: $NEW_HOSTNAME | Interface: $INTERFACE | IP: $SERVER_IP (Gateway: $GATEWAY_IP)"
echo "[+] Firewall active: SSH restricted to $ALLOWED_SUBNET_1 and $ALLOWED_SUBNET_2"

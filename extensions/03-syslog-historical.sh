#!/bin/bash

echo "[+] Running historical syslog backfill extension..."

# Load configuration if available
if [ -f "./net_config.env" ]; then
  source "./net_config.env"
elif [ -f "/tmp/net_config.env" ]; then
  source "/tmp/net_config.env"
fi

if [ "$ENABLE_REMOTE_SYSLOG" = "true" ]; then
  echo "[+] Configuring Rsyslog imfile module for historical log forwarding..."

  cat << 'EOF' > /etc/rsyslog.d/forward-historical.conf
module(load="imfile")

input(type="imfile"
      File="/var/log/auth.log"
      Tag="historical-auth"
      Severity="info"
      Facility="auth")

input(type="imfile"
      File="/var/log/syslog"
      Tag="historical-syslog"
      Severity="notice"
      Facility="user")
EOF

  systemctl restart rsyslog
  echo "[+] Historical log streaming configured and rsyslog restarted successfully."
else
  echo "[-] ENABLE_REMOTE_SYSLOG is not enabled. Skipping historical backfill."
fi

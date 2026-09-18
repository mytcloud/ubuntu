# ---------------------------------------------------------
# Interactive Deployment Configuration & Validation
# ---------------------------------------------------------
while true; do
  clear
  echo "=================================================="
  echo "         SERVER PROVISIONING CONFIGURATION        "
  echo "=================================================="
  
  # Auto-detect primary network interface
  PRIMARY_INTERFACE=$(ip -route show default | awk '/default/ {print $5}' | head -n1)
  echo "[*] Detected primary network interface: ${PRIMARY_INTERFACE:-eth0}"
  
  read -p "Enter Static IP Address (e.g., 192.168.1.100): " INPUT_IP
  read -p "Enter Subnet Mask Prefix (e.g., 24 for 255.255.255.0): " INPUT_PREFIX
  read -p "Enter Gateway IP Address (e.g., 192.168.1.1): " INPUT_GATEWAY
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

  if [ -z "$INPUT_IP" ] || [ -z "$INPUT_PREFIX" ] || [ -z "$INPUT_GATEWAY" ] || [ -z "$INPUT_HOSTNAME" ] || [ -z "$INPUT_PASSWORD" ]; then
    echo "[-] All fields are required. Please try again."
    sleep 2
    continue
  fi

  echo
  echo "--------------------------------------------------"
  echo "             CONFIGURATION REVIEW                 "
  echo "--------------------------------------------------"
  echo " Interface:    ${PRIMARY_INTERFACE:-eth0}"
  echo " IP Address:   $INPUT_IP/$INPUT_PREFIX"
  echo " Gateway:      $INPUT_GATEWAY"
  echo " Hostname:     $INPUT_HOSTNAME"
  echo " Root Password: [SECURELY CONFIGURED]"
  echo "--------------------------------------------------"
  
  read -p "Do you want to apply these settings? (y/N): " CONFIRM
  if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    break
  else
    echo "[+] Restarting input prompts..."
    sleep 2
  fi
done

# ---------------------------------------------------------
# Apply Configuration Dynamically
# ---------------------------------------------------------
INTERFACE_NAME="${PRIMARY_INTERFACE:-eth0}"

echo "[+] Applying network configuration via Netplan..."
cat << EOF > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_NAME:
      dhcp4: no
      addresses:
        - $INPUT_IP/$INPUT_PREFIX
      routes:
        - to: default
          via: $INPUT_GATEWAY
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
EOF

netplan apply
echo "[+] Network applied successfully."

echo "[+] Setting hostname to $INPUT_HOSTNAME..."
hostnamectl set-hostname "$INPUT_HOSTNAME"

echo "[+] Setting root password..."
echo "root:$INPUT_PASSWORD" | chpasswd
echo "[+] Root password updated successfully."

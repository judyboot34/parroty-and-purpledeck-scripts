#!/bin/bash
# failover-gate-setup.sh - Configure failover-gate architecture
# Run after node-personality.sh on every node
# Sets up upstream profiles, enables autoconnect, and persistent gw_mode switching

set -e
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

# 1. Detect radios (same as personality.sh)
detect_driver(){ basename "$(readlink /sys/class/net/$1/device/driver 2>/dev/null)" 2>/dev/null; }

HALOW=""; DONGLE_AP=""; DONGLE_UPLINK=""; BUILTIN=""
for w in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do
  D=$(detect_driver "$w")
  case "$D" in
    morse*)               HALOW="$w" ;;
    brcmfmac*)            BUILTIN="$w" ;;
    rtw*8812*|rtl8812*)   DONGLE_AP="$w" ;;
    rtw*8821*|rtl8821*)   DONGLE_UPLINK="$w" ;;
  esac
done

echo "===== Detected radios ====="
echo "  HaLow   : ${HALOW:-MISSING}"
echo "  Uplink  : ${DONGLE_UPLINK:-builtin or MISSING}"
echo "  AP      : ${DONGLE_AP:-builtin or MISSING}"
echo

# 2. Create/update upstream wifi profiles with priorities
PROFILES=("have-you-ever:40" "ramjam:30" "slammin-clam:20" "clam:10")

echo "[A] Setting up upstream profiles with autoconnect=yes"
for PROF_PAIR in "${PROFILES[@]}"; do
  PROF="${PROF_PAIR%:*}"
  PRIO="${PROF_PAIR#*:}"
  
  if nmcli connection show "$PROF" &>/dev/null; then
    nmcli connection modify "$PROF" connection.autoconnect yes 2>/dev/null || true
    nmcli connection modify "$PROF" connection.read-only no 2>/dev/null || true
  else
    echo "    WARN: $PROF not found (will need manual setup)"
  fi
done

# 3. Concurrent AP+STA on builtin radio if needed
if [ -n "$BUILTIN" ] && [ -z "$DONGLE_AP" ]; then
  echo "[B] Configuring concurrent AP+STA on builtin ($BUILTIN)"
  # brcmfmac supports this; just needs AP profile on same interface
  echo "    (AP profile will use $BUILTIN)"
fi

# 4. Create persistent gw_mode watcher service
echo "[C] Installing persistent gw_mode watcher"
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/gw-mode-watcher.sh <<'GWSH'
#!/bin/bash
# Check if any upstream profile is connected; set gw_mode accordingly
while true; do
  CONN=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null | grep "802-11-wireless" | cut -d: -f3)
  if [ -n "$CONN" ] && [ "$CONN" != "N/A" ]; then
    # Uplink is up
    batctl -m bat0 gw_mode server 2>/dev/null || true
  else
    # Uplink is down
    batctl -m bat0 gw_mode client 2>/dev/null || true
  fi
  sleep 10
done
GWSH
chmod +x /usr/local/sbin/gw-mode-watcher.sh

mkdir -p /etc/systemd/system
cat > /etc/systemd/system/purpledeck-gw-watcher.service <<'GWUNIT'
[Unit]
Description=PurpleDeck Gateway Mode Watcher
After=network.target purpledeck-mesh.service
Wants=purpledeck-mesh.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/gw-mode-watcher.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
GWUNIT

systemctl daemon-reload
systemctl enable purpledeck-gw-watcher.service
systemctl restart purpledeck-gw-watcher.service

echo
echo "===== DONE ====="
echo "Failover-gate configured. Gateway mode will now switch dynamically."
echo "Check status:  systemctl status purpledeck-gw-watcher"
echo "Logs:          journalctl -u purpledeck-gw-watcher -f"

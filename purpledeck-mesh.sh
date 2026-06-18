#!/usr/bin/env bash
###############################################################################
# purpledeck-mesh.sh - PurpleDeck network/mesh bring-up + PERSISTENCE
#
# Ships on the image with NO secrets inside. On first interactive run it PROMPTS
# the user to set the "purpledeck" Wi-Fi password and saves it root-only to
#   /etc/purpledeck/mesh.conf   (chmod 600, NOT part of the image)
# The boot service reads that file, so the password never lives in this script.
#
# Run AFTER the HaLow driver installer (a 'morse' wlan iface must exist).
# Applies the mesh live AND installs a systemd service so it re-applies on boot.
# Re-runnable: it cleans up any prior ad-hoc state first.
#
# ARCHITECTURE (this node = GATE):
#   UPLINK : USB dongle already on your hotspot via NetworkManager (untouched).
#   HaLow  : open 802.11s mesh-point + batman-adv (BATMAN_V) on bat0.
#   AP     : onboard radio -> WPA2 "purpledeck", bridged onto the mesh (br0).
#   GATE   : br0 = 10.41.0.1/16 + DHCP (dnsmasq) + NAT out the uplink.
# Interfaces detected BY DRIVER (morse / brcmfmac / default-route iface).
#
# Recovery: 'pd-net-down'. Disable persistence: systemctl disable purpledeck-mesh
###############################################################################
set -uo pipefail
SELF="$(readlink -f "$0")"
[ "$(id -u)" -ne 0 ] && exec sudo -E bash "$SELF" "$@"

CONF="/etc/purpledeck/mesh.conf"          # holds the AP password (root-only)
[ -r "$CONF" ] && . "$CONF"               # may define PD_AP_PASS / PD_AP_SSID

#============================ CONFIG (no secrets) ===========================
ROLE="${PD_ROLE:-gate}"
MESH_ID="${PD_MESH_ID:-purpledeck}"
MESH_FREQ="${PD_MESH_FREQ:-5180}"          # dot11ah-mapped; SAME on all nodes
AP_SSID="${PD_AP_SSID:-purpledeck}"
AP_PASS="${PD_AP_PASS:-}"                  # NO default; set by prompt/conf/env
AP_CHANNEL="${PD_AP_CHANNEL:-6}"
GATE_IP="${PD_GATE_IP:-10.41.0.1}"
MESH_CIDR="${PD_MESH_CIDR:-16}"
DHCP_FROM="${PD_DHCP_FROM:-10.41.0.10}"
DHCP_TO="${PD_DHCP_TO:-10.41.0.250}"
BATMAN_ALGO="${PD_BATMAN_ALGO:-BATMAN_V}"
ASSUME_YES="${PD_YES:-0}"                  # 1 = no consent prompt (boot uses 1)
DO_PERSIST="${PD_PERSIST:-1}"
INSTALL_DIR="/opt/purpledeck"
#============================================================================

say(){ echo "[pd-mesh] $*"; }
die(){ echo "[pd-mesh] FATAL: $*" >&2; exit 1; }
drv(){ basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; }
find_halow(){ local i; for i in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do [ "$(drv "$i")" = "morse" ] || [ "$(drv "$i")" = "morse_spi" ] && { echo "$i"; return; }; done; }
find_ap(){ local i; for i in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do [ "$(drv "$i")" = "brcmfmac" ] && { echo "$i"; return; }; done; }
find_uplink(){ ip route show default 2>/dev/null | grep -oE 'dev wl[^ ]+' | awk '{print $2}' | head -1; }

HALOW=""; for _ in $(seq 1 30); do HALOW="$(find_halow)"; [ -n "$HALOW" ] && break; sleep 1; done
[ -n "$HALOW" ] || die "no HaLow interface (driver 'morse') - run the HaLow driver installer + reboot first"
AP_IF="$(find_ap)"; [ -n "$AP_IF" ] || die "no onboard Wi-Fi (brcmfmac) for the AP"
UPLINK=""
if [ "$ROLE" = "gate" ]; then for _ in $(seq 1 45); do UPLINK="$(find_uplink)"; [ -n "$UPLINK" ] && [ "$UPLINK" != "$AP_IF" ] && break; sleep 1; done; fi
[ "$UPLINK" = "$AP_IF" ] && UPLINK=""
say "HaLow=$HALOW  AP=$AP_IF  UPLINK=${UPLINK:-none}  role=$ROLE  persist=$DO_PERSIST"

# ---- consent (interactive only) ----
if [ "$ASSUME_YES" != "1" ]; then
  echo; echo "  $AP_IF becomes the '$AP_SSID' AP. SSH over that radio WILL drop."
  echo "  Reach the Pi via the uplink IP, by joining '$AP_SSID', or console. Undo: pd-net-down"; echo
  read -r -p "  Proceed? [y/N] " a < /dev/tty || a=n
  [ "$a" = "y" ] || [ "$a" = "Y" ] || die "aborted by user"
fi

# ---- AP password: env/conf, else PROMPT (interactive) and save root-only ----
if [ -z "$AP_PASS" ]; then
  if [ -e /dev/tty ] && [ "$ASSUME_YES" != "1" ]; then
    while :; do
      read -rs -p "  Set a Wi-Fi password for '$AP_SSID' (>=8 chars): " p1 < /dev/tty; echo
      read -rs -p "  Confirm: " p2 < /dev/tty; echo
      [ "$p1" = "$p2" ] || { echo "  passwords differ - try again"; continue; }
      [ ${#p1} -ge 8 ]  || { echo "  must be at least 8 characters"; continue; }
      AP_PASS="$p1"; break
    done
    install -d -m700 "$(dirname "$CONF")"
    ( umask 077; printf 'PD_AP_PASS=%q\n' "$AP_PASS" > "$CONF" ); chmod 600 "$CONF"
    say "AP password saved root-only to $CONF (not in this script)"
  fi
fi

# ---- deps ----
export DEBIAN_FRONTEND=noninteractive
apt_try(){ local p="$1" n=0; while [ $n -lt 4 ]; do apt-get install -y --fix-missing "$p" >/dev/null 2>&1 && return 0; n=$((n+1)); sleep 3; apt-get update -y >/dev/null 2>&1 || true; done; return 1; }
if ! { command -v iw>/dev/null && command -v batctl>/dev/null && command -v hostapd>/dev/null && command -v dnsmasq>/dev/null && command -v iptables>/dev/null; }; then
  apt-get update -y >/dev/null 2>&1 || true
  for p in iw batctl hostapd dnsmasq iptables; do command -v "$p">/dev/null || apt_try "$p" || say "WARN could not install $p"; done
fi
for b in iw batctl hostapd dnsmasq; do command -v "$b">/dev/null || die "$b missing"; done

# ---- clean up ANY prior state ----
say "clearing prior network state"
systemctl stop hostapd 2>/dev/null; systemctl disable hostapd 2>/dev/null
systemctl stop dnsmasq 2>/dev/null; systemctl disable dnsmasq 2>/dev/null
systemctl stop hostapd-wpe 2>/dev/null
pkill -x hostapd 2>/dev/null; pkill -x hostapd-wpe 2>/dev/null; pkill -f 'dnsmasq.*pd-' 2>/dev/null
if ip link show bat0 >/dev/null 2>&1; then batctl meshif bat0 interface del "$HALOW" 2>/dev/null; ip link set bat0 down 2>/dev/null; ip link del bat0 2>/dev/null; fi
ip link set br0 down 2>/dev/null; ip link del br0 2>/dev/null
command -v nmcli >/dev/null && { nmcli dev set "$AP_IF" managed no 2>/dev/null; nmcli dev set "$HALOW" managed no 2>/dev/null; } || true

# ---- HaLow 802.11s mesh point (OPEN) ----
say "HaLow mesh '$MESH_ID' @ $MESH_FREQ"
ip link set "$HALOW" down 2>/dev/null
if ! iw dev "$HALOW" set type mp 2>/dev/null; then
  PHY="$(cat /sys/class/net/$HALOW/phy80211/name)"; iw dev "$HALOW" del 2>/dev/null; iw phy "$PHY" interface add "$HALOW" type mp 2>/dev/null
fi
ip link set "$HALOW" mtu 1532 2>/dev/null || true
ip link set "$HALOW" up
iw dev "$HALOW" mesh join "$MESH_ID" freq "$MESH_FREQ" 2>/dev/null \
  || iw dev "$HALOW" mesh join "$MESH_ID" 2>/dev/null \
  || say "WARN mesh join nonzero (check freq/regdomain; all nodes need same freq)"
iw dev "$HALOW" set mesh_param mesh_fwding 0 2>/dev/null || true

# ---- batman-adv ----
say "batman-adv ($BATMAN_ALGO)"
modprobe batman_adv 2>/dev/null || die "batman_adv module unavailable"
batctl routing_algo "$BATMAN_ALGO" 2>/dev/null || true
batctl meshif bat0 interface add "$HALOW" 2>/dev/null || batctl if add "$HALOW" 2>/dev/null || die "batctl add failed"
ip link set bat0 up

# ---- bridge: bat0 + AP ----
say "bridge br0"
ip link add name br0 type bridge 2>/dev/null || true
ip link set bat0 master br0 2>/dev/null || true
ip link set br0 up

# ---- AP (onboard) -> WPA2, bridged to br0 (skipped safely if no password) ----
if [ -z "$AP_PASS" ]; then
  say "WARN no AP password set - skipping client AP (mesh+batman still up)."
  say "     Run 'sudo $INSTALL_DIR/purpledeck-mesh.sh' once interactively to set one."
else
  [ ${#AP_PASS} -ge 8 ] || die "AP password must be >=8 chars"
  install -d /etc/hostapd
  ( umask 077; cat > /etc/hostapd/purpledeck.conf <<EOF
interface=$AP_IF
bridge=br0
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$AP_PASS
EOF
  )
  ip link set "$AP_IF" up 2>/dev/null
  hostapd -B /etc/hostapd/purpledeck.conf >/var/log/pd-hostapd.log 2>&1 || say "WARN hostapd nonzero (see /var/log/pd-hostapd.log)"
fi

# ---- GATE: address + DHCP + NAT ----
if [ "$ROLE" = "gate" ]; then
  ip addr flush dev br0 2>/dev/null || true
  ip addr add "$GATE_IP/$MESH_CIDR" dev br0
  pkill -f 'dnsmasq.*pd-mesh' 2>/dev/null || true
  dnsmasq --conf-file=/dev/null --pid-file=/run/pd-dnsmasq.pid --interface=br0 --bind-interfaces \
    --except-interface=lo --dhcp-range="$DHCP_FROM,$DHCP_TO,255.255.0.0,12h" \
    --dhcp-option=3,"$GATE_IP" --dhcp-option=6,"$GATE_IP",1.1.1.1 \
    --log-facility=/var/log/pd-dnsmasq.log --log-tag=pd-mesh 2>/dev/null && say "dnsmasq up" || say "WARN dnsmasq failed"
  sysctl -qw net.ipv4.ip_forward=1
  if [ -n "$UPLINK" ]; then
    say "NAT out $UPLINK"
    iptables -t nat -C POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o "$UPLINK" -j MASQUERADE
    iptables -C FORWARD -i br0 -o "$UPLINK" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i br0 -o "$UPLINK" -j ACCEPT
    iptables -C FORWARD -i "$UPLINK" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$UPLINK" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
  else
    say "WARN no uplink at apply time - mesh+AP+DHCP up, NAT skipped (set on next boot if uplink present)"
  fi
fi

# ---- recovery command ----
cat > /usr/local/bin/pd-net-down <<EOF
#!/usr/bin/env bash
pkill -f 'dnsmasq.*pd-' 2>/dev/null; pkill -x hostapd 2>/dev/null
[ -n "$UPLINK" ] && iptables -t nat -D POSTROUTING -o "$UPLINK" -j MASQUERADE 2>/dev/null
batctl meshif bat0 interface del "$HALOW" 2>/dev/null; ip link set bat0 down 2>/dev/null; ip link del bat0 2>/dev/null
ip link set br0 down 2>/dev/null; ip link del br0 2>/dev/null
ip addr flush dev "$HALOW" 2>/dev/null; ip link set "$HALOW" down 2>/dev/null
command -v nmcli >/dev/null && { nmcli dev set "$AP_IF" managed yes 2>/dev/null; nmcli dev set "$HALOW" managed yes 2>/dev/null; }
echo "PurpleDeck network down; $AP_IF returned to NetworkManager."
EOF
chmod +x /usr/local/bin/pd-net-down

# ---- PERSISTENCE ----
if [ "$DO_PERSIST" = "1" ]; then
  say "installing persistence (systemd service)"
  install -d "$INSTALL_DIR"
  [ "$SELF" = "$INSTALL_DIR/purpledeck-mesh.sh" ] || install -m755 "$SELF" "$INSTALL_DIR/purpledeck-mesh.sh"
  cat > /etc/systemd/system/purpledeck-mesh.service <<EOF
[Unit]
Description=PurpleDeck mesh + AP + gate
After=multi-user.target start_morse.service NetworkManager.service
Wants=start_morse.service
[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PD_YES=1 PD_PERSIST=0
ExecStart=$INSTALL_DIR/purpledeck-mesh.sh
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable purpledeck-mesh.service >/dev/null 2>&1 && say "boot service enabled" || say "WARN enable failed"
fi

echo
say "DONE ($ROLE). Verify:"
say "  peers : batctl meshif bat0 neighbors   (blank until a 2nd node joins)"
say "  net   : ip -br addr show br0 ; ip -br link show bat0"
say "  AP    : tail /var/log/pd-hostapd.log"
say "  undo  : sudo pd-net-down    persist off: sudo systemctl disable purpledeck-mesh"

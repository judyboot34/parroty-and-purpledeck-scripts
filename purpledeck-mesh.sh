#!/usr/bin/env bash
###############################################################################
# purpledeck-mesh.sh - PurpleDeck network/mesh bring-up + PERSISTENCE
#
# KEY FIX v2: Concurrent AP+STA on single-radio nodes
#   - Creates ap0 virtual interface on builtin radio
#   - Hostapd uses ap0 ONLY — base interface stays NM-managed for STA scanning
#   - wlan0 remains available for upstream wifi connection at all times
#   - Works with or without USB dongle (auto-detects and assigns roles)
#
# Ships on the image with NO secrets inside. Reads /etc/purpledeck/mesh.conf
# for passwords and interface assignments written by pd-firstboot.sh.
###############################################################################
set -uo pipefail
SELF="$(readlink -f "$0")"
[ "$(id -u)" -ne 0 ] && exec sudo -E bash "$SELF" "$@"

CONF="/etc/purpledeck/mesh.conf"
[ -r "$CONF" ] && . "$CONF"

#============================ CONFIG =========================================
ROLE="${PD_ROLE:-point}"
MESH_ID="${PD_MESH_ID:-purpledeck}"
MESH_FREQ="${PD_MESH_FREQ:-5180}"
MESH_IF="${PD_MESH_IF:-}"
AP_SSID="${PD_AP_SSID:-purpledeck}"
AP_PASS="${PD_AP_PASS:-}"
AP_CHANNEL="${PD_AP_CHANNEL:-6}"
GATE_IP="${PD_GATE_IP:-10.41.0.1}"
MESH_CIDR="${PD_MESH_CIDR:-16}"
DHCP_FROM="${PD_DHCP_FROM:-10.41.0.10}"
DHCP_TO="${PD_DHCP_TO:-10.41.0.250}"
BATMAN_ALGO="${PD_BATMAN_ALGO:-BATMAN_V}"
ASSUME_YES="${PD_YES:-0}"
DO_PERSIST="${PD_PERSIST:-1}"
INSTALL_DIR="/opt/purpledeck"
#=============================================================================

say(){ echo "[pd-mesh] $*"; }
die(){ echo "[pd-mesh] FATAL: $*" >&2; exit 1; }
drv(){ basename "$(readlink -f "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null; }

find_halow(){
    local i
    for i in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do
        local d; d=$(drv "$i")
        [ "$d" = "morse" ] || [ "$d" = "morse_spi" ] && { echo "$i"; return; }
    done
}

find_builtin(){
    local i
    for i in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do
        [ "$(drv "$i")" = "brcmfmac" ] && { echo "$i"; return; }
    done
}

find_dongle_uplink(){
    local i
    for i in $(ls /sys/class/net 2>/dev/null | grep '^wl'); do
        local d; d=$(drv "$i")
        echo "$d" | grep -qE 'rtw.*8821|rtl8821' && { echo "$i"; return; }
    done
}

find_uplink_iface(){
    ip route show default 2>/dev/null | grep -oE 'dev wl[^ ]+' | awk '{print $2}' | head -1
}

# ---- detect interfaces ----
HALOW=""
for _ in $(seq 1 30); do
    HALOW="$(find_halow)"
    [ -n "$HALOW" ] && break
    sleep 1
done
[ -n "$HALOW" ] || die "no HaLow interface (morse driver) — run HaLow installer + reboot"

BUILTIN="$(find_builtin)"
[ -n "$BUILTIN" ] || die "no builtin WiFi interface (brcmfmac)"

DONGLE_UPLINK="$(find_dongle_uplink)"

# Role assignment — prefer conf values, auto-detect if missing
if [ -n "${PD_UPLINK_IF:-}" ]; then
    UPLINK_IF="$PD_UPLINK_IF"
else
    UPLINK_IF="${DONGLE_UPLINK:-$BUILTIN}"
fi

# Single radio = builtin only (no dongle)
if [ -z "$DONGLE_UPLINK" ]; then
    SINGLE_RADIO=1
    UPLINK_IF="$BUILTIN"
else
    SINGLE_RADIO=0
    UPLINK_IF="$DONGLE_UPLINK"
fi

say "HaLow=$HALOW  Builtin=$BUILTIN  Uplink=$UPLINK_IF  Single-radio=$SINGLE_RADIO  role=$ROLE"

# ---- consent (interactive only) ----
if [ "$ASSUME_YES" != "1" ]; then
    echo
    echo "  Setting up PurpleDeck mesh on this device."
    echo "  HaLow mesh interface: $HALOW"
    echo "  AP will broadcast as: $AP_SSID"
    echo "  Upstream WiFi ($UPLINK_IF) will remain available for scanning."
    echo "  Undo: pd-net-down"
    echo
    read -r -p "  Proceed? [y/N] " a < /dev/tty || a=n
    [ "$a" = "y" ] || [ "$a" = "Y" ] || die "aborted by user"
fi

# ---- AP password ----
if [ -z "$AP_PASS" ]; then
    if [ -e /dev/tty ] && [ "$ASSUME_YES" != "1" ]; then
        while :; do
            read -rs -p "  Set WiFi password for '$AP_SSID' (>=8 chars): " p1 < /dev/tty; echo
            read -rs -p "  Confirm: " p2 < /dev/tty; echo
            [ "$p1" = "$p2" ] || { echo "  Passwords differ — try again"; continue; }
            [ ${#p1} -ge 8 ]  || { echo "  Must be at least 8 characters"; continue; }
            AP_PASS="$p1"; break
        done
        install -d -m700 "$(dirname "$CONF")"
        ( umask 077; printf 'PD_AP_PASS=%q\n' "$AP_PASS" >> "$CONF" )
        chmod 600 "$CONF"
        say "AP password saved to $CONF"
    fi
fi

# ---- deps ----
export DEBIAN_FRONTEND=noninteractive
apt_try(){ local p="$1" n=0; while [ $n -lt 4 ]; do apt-get install -y --fix-missing "$p" >/dev/null 2>&1 && return 0; n=$((n+1)); sleep 3; apt-get update -y >/dev/null 2>&1 || true; done; return 1; }
if ! { command -v iw>/dev/null && command -v batctl>/dev/null && command -v hostapd>/dev/null && command -v dnsmasq>/dev/null; }; then
    apt-get update -y >/dev/null 2>&1 || true
    for p in iw batctl hostapd dnsmasq iptables; do
        command -v "$p" >/dev/null || apt_try "$p" || say "WARN could not install $p"
    done
fi
for b in iw batctl hostapd dnsmasq; do command -v "$b" >/dev/null || die "$b missing — install it"; done

# ---- clean up prior state ----
say "clearing prior network state"
systemctl stop hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
pkill -x hostapd 2>/dev/null || true
pkill -f 'dnsmasq.*pd-' 2>/dev/null || true

# Remove ap0 if it exists
ip link show ap0 >/dev/null 2>&1 && {
    ip link set ap0 down 2>/dev/null || true
    iw dev ap0 del 2>/dev/null || true
}

# Remove bat0 and br0
ip link show bat0 >/dev/null 2>&1 && {
    batctl meshif bat0 interface del "$HALOW" 2>/dev/null || true
    ip link set bat0 down 2>/dev/null || true
    ip link del bat0 2>/dev/null || true
}
ip link show br0 >/dev/null 2>&1 && {
    ip link set br0 down 2>/dev/null || true
    ip link del br0 2>/dev/null || true
}

# Tell NM to leave HaLow alone — but KEEP builtin managed
nmcli dev set "$HALOW" managed no 2>/dev/null || true
# Ensure builtin stays managed by NM (critical for STA scanning)
nmcli dev set "$BUILTIN" managed yes 2>/dev/null || true

# ---- HaLow 802.11s mesh ----
say "HaLow mesh '$MESH_ID' @ $MESH_FREQ"
ip link set "$HALOW" down 2>/dev/null || true
if ! iw dev "$HALOW" set type mp 2>/dev/null; then
    PHY="$(cat /sys/class/net/$HALOW/phy80211/name 2>/dev/null)"
    iw dev "$HALOW" del 2>/dev/null || true
    iw phy "$PHY" interface add "$HALOW" type mp 2>/dev/null || true
fi
ip link set "$HALOW" mtu 1532 2>/dev/null || true
ip link set "$HALOW" up
iw dev "$HALOW" mesh join "$MESH_ID" freq "$MESH_FREQ" 2>/dev/null \
    || iw dev "$HALOW" mesh join "$MESH_ID" 2>/dev/null \
    || say "WARN mesh join nonzero (check freq/regdomain)"
iw dev "$HALOW" set mesh_param mesh_fwding 0 2>/dev/null || true

# ---- batman-adv ----
say "batman-adv ($BATMAN_ALGO)"
modprobe batman_adv 2>/dev/null || die "batman_adv module unavailable"
batctl routing_algo "$BATMAN_ALGO" 2>/dev/null || true
batctl meshif bat0 interface add "$HALOW" 2>/dev/null \
    || batctl if add "$HALOW" 2>/dev/null \
    || die "batctl add failed"
ip link set bat0 up

# ---- bridge: bat0 only (ap0 added after creation) ----
say "bridge br0"
ip link add name br0 type bridge 2>/dev/null || true
ip link set bat0 master br0 2>/dev/null || true
ip link set br0 up

# ---- AP: create ap0 virtual interface, run hostapd on ap0 only ----
# This leaves wlan0 (builtin) fully available for NM STA scanning + uplink
if [ -z "$AP_PASS" ]; then
    say "WARN no AP password — skipping client AP (mesh still up)"
    say "     Run script interactively to set password, or set PD_AP_PASS in $CONF"
else
    [ ${#AP_PASS} -ge 8 ] || die "AP password must be >=8 chars"

    say "Creating ap0 virtual AP interface on $BUILTIN"
    iw dev "$BUILTIN" interface add ap0 type __ap 2>/dev/null && {
        say "ap0 created — concurrent AP+STA enabled"
        nmcli dev set ap0 managed no 2>/dev/null || true
        ip link set ap0 up 2>/dev/null || true
        AP_IFACE="ap0"
    } || {
        say "WARN ap0 creation failed — falling back to $BUILTIN directly"
        say "     NM will not be able to scan for upstream networks while AP is running"
        nmcli dev set "$BUILTIN" managed no 2>/dev/null || true
        AP_IFACE="$BUILTIN"
    }

    # Add AP interface to bridge
    ip link set "$AP_IFACE" master br0 2>/dev/null || true

    # Write hostapd config using AP_IFACE (ap0 or fallback)
    install -d /etc/hostapd
    ( umask 077; cat > /etc/hostapd/purpledeck.conf <<EOF
interface=$AP_IFACE
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

    hostapd -B /etc/hostapd/purpledeck.conf >/var/log/pd-hostapd.log 2>&1 \
        && say "hostapd running on $AP_IFACE" \
        || say "WARN hostapd nonzero — check /var/log/pd-hostapd.log"
fi

# ---- GATE: IP + DHCP + NAT ----
if [ "$ROLE" = "gate" ]; then
    ip addr flush dev br0 2>/dev/null || true
    ip addr add "$GATE_IP/$MESH_CIDR" dev br0

    # Find active uplink for NAT
    ACTIVE_UPLINK=""
    for _ in $(seq 1 10); do
        ACTIVE_UPLINK="$(find_uplink_iface)"
        [ -n "$ACTIVE_UPLINK" ] && [ "$ACTIVE_UPLINK" != "ap0" ] && [ "$ACTIVE_UPLINK" != "br0" ] && break
        sleep 2
    done

    cat > /etc/systemd/system/purpledeck-dnsmasq.service <<UNITEOF
[Unit]
Description=PurpleDeck DHCP (dnsmasq on br0)
[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/dev/null \
  --interface=br0 --bind-interfaces --port=0 --except-interface=lo \
  --dhcp-range=${DHCP_FROM},${DHCP_TO},255.255.0.0,12h \
  --dhcp-option=3,${GATE_IP} \
  --dhcp-option=6,1.1.1.1,8.8.8.8 \
  --log-facility=/var/log/pd-dnsmasq.log
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNITEOF

    systemctl daemon-reload
    systemctl enable purpledeck-dnsmasq.service >/dev/null 2>&1 || true
    systemctl restart purpledeck-dnsmasq 2>/dev/null \
        && say "dnsmasq up" \
        || say "WARN dnsmasq failed"

    sysctl -qw net.ipv4.ip_forward=1

    if [ -n "$ACTIVE_UPLINK" ]; then
        say "NAT out $ACTIVE_UPLINK"
        iptables -t nat -C POSTROUTING -o "$ACTIVE_UPLINK" -j MASQUERADE 2>/dev/null \
            || iptables -t nat -A POSTROUTING -o "$ACTIVE_UPLINK" -j MASQUERADE
        iptables -C FORWARD -i br0 -o "$ACTIVE_UPLINK" -j ACCEPT 2>/dev/null \
            || iptables -A FORWARD -i br0 -o "$ACTIVE_UPLINK" -j ACCEPT
        iptables -C FORWARD -i "$ACTIVE_UPLINK" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
            || iptables -A FORWARD -i "$ACTIVE_UPLINK" -o br0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    else
        say "WARN no uplink — NAT skipped (will apply on next boot if uplink present)"
    fi
fi

# ---- recovery command ----
cat > /usr/local/bin/pd-net-down <<'DOWNEOF'
#!/usr/bin/env bash
pkill -x hostapd 2>/dev/null || true
pkill -f 'dnsmasq.*pd-' 2>/dev/null || true
iw dev ap0 del 2>/dev/null || true
batctl meshif bat0 interface del "$(cat /var/lib/purpledeck/radios.env 2>/dev/null | grep HALOW_IF | cut -d= -f2)" 2>/dev/null || true
ip link set bat0 down 2>/dev/null; ip link del bat0 2>/dev/null
ip link set br0 down 2>/dev/null; ip link del br0 2>/dev/null
nmcli dev set "$(cat /var/lib/purpledeck/radios.env 2>/dev/null | grep BUILTIN_IF | cut -d= -f2)" managed yes 2>/dev/null || true
echo "PurpleDeck network down. Builtin WiFi returned to NetworkManager."
DOWNEOF
chmod +x /usr/local/bin/pd-net-down

# ---- persistence ----
if [ "$DO_PERSIST" = "1" ]; then
    say "installing systemd service"
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
    systemctl enable purpledeck-mesh.service >/dev/null 2>&1 \
        && say "boot service enabled" \
        || say "WARN enable failed"
fi

echo
say "DONE ($ROLE). Verify:"
say "  peers   : batctl meshif bat0 n   (blank until 2nd node joins)"
say "  net     : ip -br addr show br0"
say "  AP      : tail /var/log/pd-hostapd.log"
say "  NM scan : nmcli dev wifi list    (should work even with mesh running)"
say "  undo    : sudo pd-net-down"

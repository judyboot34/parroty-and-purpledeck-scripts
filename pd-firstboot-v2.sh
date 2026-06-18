#!/bin/bash
# =============================================================================
# PurpleDeck Universal First-Boot Orchestrator v2
# Install to: /opt/purpledeck/scripts/pd-firstboot.sh
#
# New in v2:
#   - Username support (persistent, user-chosen)
#   - Ephemeral hostnames (regenerated each boot)
#   - Combined mDNS: {username}-{hostname}.local (persistent)
#   - Collision-avoidance on full username-hostname combo
#   - Known-nodes registry for future channel discovery
#
# Usage:
#   sudo bash pd-firstboot.sh            # normal run
#   sudo bash pd-firstboot.sh --repair   # re-run all stages
#   sudo bash pd-firstboot.sh --status   # print state, no changes
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# PATHS & CONSTANTS
# -----------------------------------------------------------------------------
PD_BASE="/opt/purpledeck"
PD_CONF="/etc/purpledeck"
PD_MESH_CONF="$PD_CONF/mesh.conf"
PD_IDENTITY_CONF="$PD_CONF/identity.conf"
PD_KNOWN_NODES="$PD_CONF/known-nodes"
PD_STATE="/var/lib/purpledeck"
PD_FIRSTBOOT_DONE="$PD_STATE/first-boot.done"
PD_LOG="/var/log/pd-firstboot.log"
STAGE_DIR="$PD_STATE/stages"

# Upstream wifi SSIDs and priorities
declare -A UPSTREAM_PRIORITIES=(
    ["have-you-ever"]="40"
    ["ramjam"]="30"
    ["slammin-clam"]="20"
    ["clam"]="10"
)

# Mesh defaults
DEFAULT_MESH_PASS="thatsanicedeck"
DEFAULT_AP_PASS="thatsanicedeck"
DEFAULT_MESH_CHANNEL="36"
DEFAULT_MESH_FREQ="5180"
DEFAULT_MESH_ID="purpledeck"
DEFAULT_BATMAN_IFACE="bat0"
DEFAULT_BRIDGE_IFACE="br0"
DEFAULT_GATEWAY_IP="10.41.0.1"

# Hostname prefixes
PREFIX_PI5="commander"
PREFIX_PIZERO="hoodlum"
PREFIX_PIZERO2W="hoodlum2w"

# -----------------------------------------------------------------------------
# ARGS
# -----------------------------------------------------------------------------
FORCE=0
STATUS_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --force|--repair) FORCE=1 ;;
        --status) STATUS_ONLY=1 ;;
    esac
done

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------
mkdir -p "$PD_STATE" "$STAGE_DIR" "$PD_CONF"
exec > >(tee -a "$PD_LOG") 2>&1

log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"; }
ok()      { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK]    $*"; }
section() { echo; echo "=============================="; echo "  $*"; echo "=============================="; }

# -----------------------------------------------------------------------------
# STAGE HELPERS
# -----------------------------------------------------------------------------
stage_done()     { touch "$STAGE_DIR/stage-$1.done"; }
stage_complete() { [ -f "$STAGE_DIR/stage-$1.done" ]; }
stage_reset()    { rm -f "$STAGE_DIR"/stage-*.done; }

# -----------------------------------------------------------------------------
# ROOT CHECK
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || { err "Run as root: sudo bash $0"; exit 1; }

# =============================================================================
# STATUS MODE
# =============================================================================
if [ "$STATUS_ONLY" -eq 1 ]; then
    section "PurpleDeck Node Status"
    [ -f "$PD_IDENTITY_CONF" ] && source "$PD_IDENTITY_CONF" || true
    echo "Username   : ${PD_USERNAME:-not set}"
    echo "Hostname   : $(hostname)"
    echo "mDNS name  : ${PD_USERNAME:-?}-$(hostname).local"
    echo "First-boot : $([ -f "$PD_FIRSTBOOT_DONE" ] && cat "$PD_FIRSTBOOT_DONE" || echo NOT COMPLETE)"
    echo "Kernel     : $(uname -r)"
    echo ""
    echo "--- Interfaces ---"
    ip -br link show | grep -E 'wlan|bat|br|eth' || true
    echo ""
    echo "--- HaLow module ---"
    lsmod | grep morse || echo "NOT LOADED"
    echo ""
    echo "--- batman-adv neighbors ---"
    batctl meshif bat0 n 2>/dev/null || echo "bat0 not up"
    echo ""
    echo "--- GW mode ---"
    batctl meshif bat0 gw_mode 2>/dev/null || echo "bat0 not up"
    echo ""
    echo "--- Active upstream ---"
    nmcli -t -f NAME,TYPE,STATE connection show --active 2>/dev/null | grep wireless || echo "none"
    echo ""
    echo "--- Known nodes ---"
    cat "$PD_KNOWN_NODES" 2>/dev/null || echo "none"
    echo ""
    echo "--- Services ---"
    for svc in start_morse morse-autoheal purpledeck-mesh purpledeck-gw-watcher purpledeck-gui purpledeck-watchdog; do
        printf "  %-35s %s\n" "$svc" "$(systemctl is-active "$svc" 2>/dev/null || echo not-found)"
    done
    exit 0
fi

# =============================================================================
# FIRST-BOOT GATE
# =============================================================================
if [ -f "$PD_FIRSTBOOT_DONE" ] && [ "$FORCE" -eq 0 ]; then
    log "First-boot already complete ($(cat $PD_FIRSTBOOT_DONE))"
    log "Use --repair to re-run all stages."
    # Even on subsequent boots, re-run hostname (ephemeral) and mDNS
    # without resetting other stages
    HOSTNAME_ONLY=1
else
    HOSTNAME_ONLY=0
fi

if [ "$FORCE" -eq 1 ]; then
    warn "Repair mode — resetting all stages"
    stage_reset
    HOSTNAME_ONLY=0
fi

log "PurpleDeck first-boot orchestrator v2 starting"

# =============================================================================
# STAGE 0 — USERNAME (persistent, set once)
# =============================================================================
section "Stage 0: Username"

if ! stage_complete 0; then
    # Check if username already set
    if [ -f "$PD_IDENTITY_CONF" ]; then
        source "$PD_IDENTITY_CONF"
        if [ -n "${PD_USERNAME:-}" ]; then
            log "Username already set: $PD_USERNAME"
            stage_done 0
        fi
    fi
fi

if ! stage_complete 0; then
    # Prompt for username on console
    echo ""
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║         PurpleDeck First Setup                   ║"
    echo "  ║                                                  ║"
    echo "  ║  Enter a username for this device.               ║"
    echo "  ║  This will be used to identify your device       ║"
    echo "  ║  on the mesh (e.g. phil-commander16.local)       ║"
    echo "  ║                                                  ║"
    echo "  ║  Lowercase letters, numbers, hyphens only.       ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo ""

    PD_USERNAME=""
    while [ -z "$PD_USERNAME" ]; do
        read -r -p "  Username: " PD_USERNAME
        # Sanitize — lowercase, only alphanumeric and hyphens
        PD_USERNAME=$(echo "$PD_USERNAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
        if [ -z "$PD_USERNAME" ]; then
            echo "  Invalid — use lowercase letters, numbers, hyphens only."
        fi
    done

    log "Username set: $PD_USERNAME"

    # Save persistently
    printf "PD_USERNAME=%s\n" "$PD_USERNAME" > "$PD_IDENTITY_CONF"
    chmod 600 "$PD_IDENTITY_CONF"

    stage_done 0
    ok "Stage 0 done — username: $PD_USERNAME"
fi

source "$PD_IDENTITY_CONF"

# =============================================================================
# STAGE 1 — HARDWARE DETECTION
# =============================================================================
section "Stage 1: Hardware Detection"

if ! stage_complete 1; then
    MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "unknown")
    log "Model: $MODEL"

    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$(awk -v kb="$RAM_KB" 'BEGIN {
        gb = kb / 1048576
        if      (gb < 1.5) print 1
        else if (gb < 3)   print 2
        else if (gb < 6)   print 4
        else if (gb < 12)  print 8
        else               print 16
    }')
    log "RAM: ${RAM_GB}GB"

    if   echo "$MODEL" | grep -qi "Zero 2"; then HW_PREFIX="$PREFIX_PIZERO2W"
    elif echo "$MODEL" | grep -qi "Zero";   then HW_PREFIX="$PREFIX_PIZERO"
    else                                         HW_PREFIX="${PREFIX_PI5}${RAM_GB}"
    fi
    log "Hardware prefix: $HW_PREFIX"

    printf "HW_PREFIX=%s\nRAM_GB=%s\nMODEL=%s\n" \
        "$HW_PREFIX" "$RAM_GB" "$MODEL" > "$PD_STATE/hardware.env"

    stage_done 1; ok "Stage 1 done"
fi
source "$PD_STATE/hardware.env"

# =============================================================================
# STAGE 2 — RADIO DETECTION
# =============================================================================
section "Stage 2: Radio Detection"

if ! stage_complete 2; then
    detect_driver() {
        basename "$(readlink "/sys/class/net/$1/device/driver" 2>/dev/null)" 2>/dev/null || echo "unknown"
    }

    HALOW_IF="" BUILTIN_IF="" DONGLE_AP_IF="" DONGLE_UPLINK_IF=""

    for iface in $(ls /sys/class/net/ 2>/dev/null | grep '^wl'); do
        drv=$(detect_driver "$iface")
        log "  $iface -> $drv"
        case "$drv" in
            morse*)                          HALOW_IF="$iface" ;;
            brcmfmac*)                       BUILTIN_IF="$iface" ;;
            rtw*8812*|rtl8812*|rtw88_8812*) DONGLE_AP_IF="$iface" ;;
            rtw*8821*|rtl8821*|rtw88_8821*) DONGLE_UPLINK_IF="$iface" ;;
        esac
    done

    log "HaLow: ${HALOW_IF:-MISSING} | Builtin: ${BUILTIN_IF:-MISSING} | Dongle AP: ${DONGLE_AP_IF:-none} | Dongle uplink: ${DONGLE_UPLINK_IF:-none}"

    if [ -n "$DONGLE_UPLINK_IF" ]; then
        PD_ROLE="gate"; PD_UPLINK_IF="$DONGLE_UPLINK_IF"
        PD_AP_IF="${DONGLE_AP_IF:-$BUILTIN_IF}"; SINGLE_RADIO=0
    else
        PD_ROLE="point"; PD_UPLINK_IF="$BUILTIN_IF"
        PD_AP_IF="$BUILTIN_IF"; SINGLE_RADIO=1
        warn "Single-radio node — concurrent AP+STA on $BUILTIN_IF"
    fi
    PD_MESH_IF="$HALOW_IF"

    log "Role: $PD_ROLE | Uplink: $PD_UPLINK_IF | AP: $PD_AP_IF | Mesh: ${PD_MESH_IF:-MISSING}"

    printf "PD_ROLE=%s\nPD_UPLINK_IF=%s\nPD_AP_IF=%s\nPD_MESH_IF=%s\nSINGLE_RADIO=%s\nHALOW_IF=%s\nBUILTIN_IF=%s\nDONGLE_AP_IF=%s\nDONGLE_UPLINK_IF=%s\n" \
        "$PD_ROLE" "$PD_UPLINK_IF" "$PD_AP_IF" "$PD_MESH_IF" "$SINGLE_RADIO" \
        "$HALOW_IF" "$BUILTIN_IF" "$DONGLE_AP_IF" "$DONGLE_UPLINK_IF" \
        > "$PD_STATE/radios.env"

    stage_done 2; ok "Stage 2 done"
fi
source "$PD_STATE/radios.env"

# =============================================================================
# STAGE 3 — HOSTNAME (EPHEMERAL — RUNS EVERY BOOT)
# =============================================================================
section "Stage 3: Hostname (ephemeral)"

# This stage always runs — hostname regenerates each boot
# We do NOT gate this on stage_complete

log "Generating ephemeral hostname for this session..."

# Scan mesh for existing hostnames AND existing username-hostname combos
EXISTING_HOSTNAMES=""
EXISTING_COMBINED=""
if command -v avahi-browse &>/dev/null; then
    DELAY=$((RANDOM % 15))
    log "Scanning mesh (random delay ${DELAY}s for race avoidance)..."
    sleep "$DELAY"
    SCAN=$(timeout 12 avahi-browse -rpt _workstation._tcp 2>/dev/null || true)
    EXISTING_HOSTNAMES=$(echo "$SCAN" \
        | grep -oE '(commander[0-9]+|hoodlum2w|hoodlum)(_[0-9]+)?' \
        | sort -u || true)
    EXISTING_COMBINED=$(echo "$SCAN" \
        | grep -oE '[a-z0-9-]+-((commander[0-9]+|hoodlum2w|hoodlum)(_[0-9]+)?)' \
        | sort -u || true)
else
    warn "avahi-browse not found — skipping collision detection"
fi

log "Existing hostnames on mesh: ${EXISTING_HOSTNAMES:-none}"
log "Existing combined names on mesh: ${EXISTING_COMBINED:-none}"

# Pick base hostname (ephemeral part)
HOST_CANDIDATE="$HW_PREFIX"
HOST_SUFFIX=1
while echo "$EXISTING_HOSTNAMES" | grep -qx "$HOST_CANDIDATE"; do
    HOST_SUFFIX=$((HOST_SUFFIX + 1))
    HOST_CANDIDATE="${HW_PREFIX}_${HOST_SUFFIX}"
    [ "$HOST_SUFFIX" -gt 999 ] && { err "Too many nodes with prefix $HW_PREFIX"; exit 1; }
done
SESSION_HOSTNAME="$HOST_CANDIDATE"

# Build combined name: {username}-{hostname}
COMBINED_CANDIDATE="${PD_USERNAME}-${SESSION_HOSTNAME}"
COMBINED_SUFFIX=1
while echo "$EXISTING_COMBINED" | grep -qx "$COMBINED_CANDIDATE"; do
    COMBINED_SUFFIX=$((COMBINED_SUFFIX + 1))
    # Append suffix to session hostname part
    SESSION_HOSTNAME="${HW_PREFIX}_${COMBINED_SUFFIX}"
    COMBINED_CANDIDATE="${PD_USERNAME}-${SESSION_HOSTNAME}"
    [ "$COMBINED_SUFFIX" -gt 999 ] && { err "Too many combined name collisions"; exit 1; }
done

log "Session hostname: $SESSION_HOSTNAME"
log "Combined name:    $COMBINED_CANDIDATE"

# Apply hostname persistently (all 3 locations)
hostnamectl set-hostname "$SESSION_HOSTNAME"
echo "$SESSION_HOSTNAME" > /etc/hostname
sed -i '/^127\.0\.1\.1/d' /etc/hosts
echo "127.0.1.1 $SESSION_HOSTNAME $COMBINED_CANDIDATE" >> /etc/hosts

# Clone hygiene on FIRST boot only (not every boot)
if [ ! -f "$PD_FIRSTBOOT_DONE" ] || [ "$FORCE" -eq 1 ]; then
    log "First boot — regenerating machine-id and SSH host keys"
    rm -f /etc/machine-id /var/lib/dbus/machine-id
    systemd-machine-id-setup
    rm -f /etc/ssh/ssh_host_*
    ssh-keygen -A 2>/dev/null || \
        dpkg-reconfigure openssh-server -f noninteractive 2>/dev/null || \
        warn "Could not regenerate SSH host keys"
fi

# Register BOTH mDNS names via avahi
# Primary stable: {username}-{hostname}.local
# Secondary temp: {hostname}.local
systemctl restart avahi-daemon 2>/dev/null || true
systemctl restart ssh 2>/dev/null || true

# Save for other stages
{
    echo "SESSION_HOSTNAME=$SESSION_HOSTNAME"
    echo "COMBINED_HOSTNAME=$COMBINED_CANDIDATE"
} > "$PD_STATE/hostname.env"

ok "Stage 3 done — session: $SESSION_HOSTNAME | permanent: $COMBINED_CANDIDATE.local"

source "$PD_STATE/hostname.env"

# If we're only doing hostname refresh on subsequent boots, stop here
if [ "${HOSTNAME_ONLY:-0}" -eq 1 ]; then
    log "Hostname refreshed for new session. Done."
    # Restart avahi to advertise new hostname
    systemctl restart avahi-daemon 2>/dev/null || true
    exit 0
fi

# =============================================================================
# STAGE 4 — NETWORKMANAGER
# =============================================================================
section "Stage 4: NetworkManager"

if ! stage_complete 4; then
    mkdir -p /etc/NetworkManager/conf.d
    rm -f /etc/NetworkManager/conf.d/purpledeck-unmanaged.conf

    if [ "$SINGLE_RADIO" -eq 1 ]; then
        printf '[device]\nmatch-device=interface-name:ap0\nmanaged=0\n' \
            > /etc/NetworkManager/conf.d/purpledeck-devices.conf
    elif [ -n "$DONGLE_AP_IF" ]; then
        printf '[device]\nmatch-device=interface-name:%s\nmanaged=0\n' "$DONGLE_AP_IF" \
            > /etc/NetworkManager/conf.d/purpledeck-devices.conf
    fi

    nmcli device set "$PD_UPLINK_IF" managed yes 2>/dev/null || true
    systemctl reload NetworkManager 2>/dev/null || \
        systemctl restart NetworkManager 2>/dev/null || true
    sleep 2

    for SSID in "${!UPSTREAM_PRIORITIES[@]}"; do
        PRIO="${UPSTREAM_PRIORITIES[$SSID]}"
        if nmcli connection show "$SSID" &>/dev/null; then
            nmcli connection modify "$SSID" \
                connection.autoconnect yes \
                connection.autoconnect-priority "$PRIO" \
                connection.read-only no 2>/dev/null && \
                ok "  Updated: $SSID (priority $PRIO)" || \
                warn "  Could not update: $SSID"
        else
            warn "  Profile '$SSID' not found — add via web UI"
        fi
    done

    BEST=$(nmcli -t -f NAME,AUTOCONNECT-PRIORITY connection show 2>/dev/null \
        | sort -t: -k2 -rn | head -1 | cut -d: -f1 || true)
    [ -n "$BEST" ] && nmcli connection up "$BEST" 2>/dev/null || true
    sleep 3

    stage_done 4; ok "Stage 4 done"
fi

# =============================================================================
# STAGE 5 — HALOW DRIVER
# =============================================================================
section "Stage 5: HaLow Driver"

if ! stage_complete 5; then
    if lsmod | grep -q morse; then
        ok "Morse driver already loaded"
    else
        log "Loading morse driver..."
        systemctl start start_morse.service 2>/dev/null || true
        sleep 5
        if lsmod | grep -q morse; then
            ok "Morse driver loaded"
        else
            warn "Morse driver failed to load"
            warn "Check: journalctl -u start_morse"
            warn "Physical: verify HAT seated on all 40 pins"
        fi
    fi

    for iface in $(ls /sys/class/net/ 2>/dev/null | grep '^wl'); do
        drv=$(basename "$(readlink "/sys/class/net/$iface/device/driver" 2>/dev/null)" 2>/dev/null || true)
        if echo "$drv" | grep -q morse; then
            HALOW_IF="$iface"; PD_MESH_IF="$iface"
            log "HaLow interface: $HALOW_IF"; break
        fi
    done

    sed -i "s|^HALOW_IF=.*|HALOW_IF=$HALOW_IF|" "$PD_STATE/radios.env"
    sed -i "s|^PD_MESH_IF=.*|PD_MESH_IF=$PD_MESH_IF|" "$PD_STATE/radios.env"

    stage_done 5; ok "Stage 5 done"
fi
source "$PD_STATE/radios.env"

# =============================================================================
# STAGE 6 — MESH.CONF
# =============================================================================
section "Stage 6: mesh.conf"

if ! stage_complete 6; then
    mkdir -p "$PD_CONF"

    EXISTING_AP_PASS=""
    EXISTING_MESH_PASS=""
    EXISTING_CHANNEL=""
    if [ -f "$PD_MESH_CONF" ]; then
        EXISTING_AP_PASS=$(grep   '^PD_AP_PASS='      "$PD_MESH_CONF" | cut -d= -f2- | tr -d '"' || true)
        EXISTING_MESH_PASS=$(grep '^PD_MESH_PASS='    "$PD_MESH_CONF" | cut -d= -f2- | tr -d '"' || true)
        EXISTING_CHANNEL=$(grep   '^PD_MESH_CHANNEL=' "$PD_MESH_CONF" | cut -d= -f2- | tr -d '"' || true)
    fi
    AP_PASS="${EXISTING_AP_PASS:-$DEFAULT_AP_PASS}"
    MESH_PASS="${EXISTING_MESH_PASS:-$DEFAULT_MESH_PASS}"
    MESH_CHANNEL="${EXISTING_CHANNEL:-$DEFAULT_MESH_CHANNEL}"

    BUILTIN_MAC=$(cat "/sys/class/net/${BUILTIN_IF}/address" 2>/dev/null \
        | tr -d ':' | tail -c 5 || echo "0000")
    AP_SSID="purpledeck"

    CONF_TMP="${PD_MESH_CONF}.tmp"
    {
        echo "# PurpleDeck mesh config — generated $(date)"
        echo "# chmod 600 — contains passwords"
        echo "PD_ROLE=\"$PD_ROLE\""
        echo "PD_AP_IF=\"$PD_AP_IF\""
        echo "PD_UPLINK_IF=\"$PD_UPLINK_IF\""
        echo "PD_MESH_IF=\"$PD_MESH_IF\""
        echo "PD_AP_SSID=\"$AP_SSID\""
        echo "PD_AP_PASS=\"$AP_PASS\""
        echo "PD_MESH_PASS=\"$MESH_PASS\""
        echo "PD_MESH_ID=\"$DEFAULT_MESH_ID\""
        echo "PD_MESH_CHANNEL=\"$MESH_CHANNEL\""
        echo "PD_MESH_FREQ=\"$DEFAULT_MESH_FREQ\""
        echo "PD_BATMAN_IFACE=\"$DEFAULT_BATMAN_IFACE\""
        echo "PD_BRIDGE_IFACE=\"$DEFAULT_BRIDGE_IFACE\""
        echo "PD_GATEWAY_IP=\"$DEFAULT_GATEWAY_IP\""
        echo "PD_HOSTNAME=\"$SESSION_HOSTNAME\""
        echo "PD_COMBINED_HOSTNAME=\"$COMBINED_HOSTNAME\""
        echo "PD_USERNAME=\"$PD_USERNAME\""
    } > "$CONF_TMP"
    mv "$CONF_TMP" "$PD_MESH_CONF"
    chmod 600 "$PD_MESH_CONF"
    log "mesh.conf written"

    stage_done 6; ok "Stage 6 done"
fi
source "$PD_MESH_CONF"

# =============================================================================
# STAGE 7 — CONCURRENT AP+STA
# =============================================================================
section "Stage 7: Concurrent AP+STA"

if ! stage_complete 7; then
    if [ "$SINGLE_RADIO" -eq 1 ] && [ -n "$BUILTIN_IF" ]; then
        log "Creating ap0 virtual interface on $BUILTIN_IF"
        if ip link show ap0 &>/dev/null; then
            log "ap0 already exists"
        else
            iw dev "$BUILTIN_IF" interface add ap0 type __ap 2>/dev/null && \
                ok "ap0 created" || \
                warn "ap0 creation failed — concurrent AP+STA not available"
        fi
        ip link show ap0 &>/dev/null && ok "Concurrent AP+STA ready" || \
            warn "Falling back: AP on $BUILTIN_IF directly — upstream STA blocked while mesh runs"
    else
        log "Dual-radio — skipping"
    fi
    stage_done 7; ok "Stage 7 done"
fi

# =============================================================================
# STAGE 8 — KNOWN NODES REGISTRY
# =============================================================================
section "Stage 8: Known Nodes Registry"

if ! stage_complete 8; then
    # Initialize known-nodes file if missing
    touch "$PD_KNOWN_NODES"
    chmod 600 "$PD_KNOWN_NODES"

    # Scan for PurpleDeck nodes on the mesh and add to known-nodes list
    # This registry will be used for future channel discovery
    if command -v avahi-browse &>/dev/null; then
        log "Scanning for known PurpleDeck nodes..."
        FOUND_NODES=$(timeout 12 avahi-browse -rpt _workstation._tcp 2>/dev/null \
            | grep -oE '[a-z0-9-]+-((commander[0-9]+|hoodlum2w|hoodlum)(_[0-9]+)?)' \
            | sort -u || true)

        for node in $FOUND_NODES; do
            if ! grep -qx "$node" "$PD_KNOWN_NODES" 2>/dev/null; then
                echo "$node" >> "$PD_KNOWN_NODES"
                log "  Added known node: $node"
            fi
        done

        # Add ourselves
        if ! grep -qx "$COMBINED_HOSTNAME" "$PD_KNOWN_NODES" 2>/dev/null; then
            echo "$COMBINED_HOSTNAME" >> "$PD_KNOWN_NODES"
            log "  Added self: $COMBINED_HOSTNAME"
        fi
    fi

    log "Known nodes: $(cat $PD_KNOWN_NODES | tr '\n' ' ')"

    # STUB: Future channel discovery
    # When channel rotation is implemented:
    # 1. For each node in known-nodes, try: curl http://{node}.local:8080/api/mesh/channel
    # 2. If any respond, adopt their advertised channel
    # 3. If none respond, pick random channel from safe list and become primary
    log "(Channel discovery stub — will query known nodes' web UIs in future version)"

    stage_done 8; ok "Stage 8 done"
fi

# =============================================================================
# STAGE 9 — GW-MODE WATCHER
# =============================================================================
section "Stage 9: Gateway Mode Watcher"

if ! stage_complete 9; then
    mkdir -p /usr/local/sbin

    python3 - <<'PYEOF'
script = r"""#!/bin/bash
# PurpleDeck gateway mode watcher v2
# Polls every 10s — server when uplink active, client otherwise
# Graceful drain before switching away from server mode

DRAIN_TIMEOUT=30
last_mode=""

has_uplink() {
    nmcli -t -f TYPE,STATE connection show --active 2>/dev/null \
        | grep -q "802-11-wireless:activated"
}

active_conns() {
    ss -tnp 2>/dev/null | grep -c ESTABLISHED || echo 0
}

set_mode() {
    local mode="$1"
    [ "$mode" = "$last_mode" ] && return
    if [ "$last_mode" = "server" ] && [ "$mode" = "client" ]; then
        local n waited=0
        n=$(active_conns)
        if [ "$n" -gt 0 ]; then
            logger -t pd-gw "Uplink lost — draining $n connections (max ${DRAIN_TIMEOUT}s)"
            while [ "$waited" -lt "$DRAIN_TIMEOUT" ]; do
                n=$(active_conns); [ "$n" -eq 0 ] && break
                sleep 2; waited=$((waited+2))
            done
        fi
    fi
    batctl -m bat0 gw_mode "$mode" 2>/dev/null \
        && logger -t pd-gw "gw_mode -> $mode (was: ${last_mode:-unset})"
    last_mode="$mode"
}

while true; do
    has_uplink && set_mode server || set_mode client
    sleep 10
done
"""
with open('/usr/local/sbin/gw-mode-watcher.sh', 'w') as f:
    f.write(script)
import os; os.chmod('/usr/local/sbin/gw-mode-watcher.sh', 0o755)
print("gw-mode-watcher.sh written")
PYEOF

    python3 - <<'PYEOF'
unit = """[Unit]
Description=PurpleDeck Gateway Mode Watcher
After=network-online.target purpledeck-mesh.service
Wants=purpledeck-mesh.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/gw-mode-watcher.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
with open('/etc/systemd/system/purpledeck-gw-watcher.service', 'w') as f:
    f.write(unit)
print("purpledeck-gw-watcher.service written")
PYEOF

    systemctl daemon-reload
    systemctl enable purpledeck-gw-watcher.service
    systemctl restart purpledeck-gw-watcher.service 2>/dev/null || true

    stage_done 9; ok "Stage 9 done"
fi

# =============================================================================
# STAGE 10 — MESH SERVICE
# =============================================================================
section "Stage 10: Mesh Service"

if ! stage_complete 10; then
    systemctl daemon-reload
    if systemctl is-enabled purpledeck-mesh.service &>/dev/null; then
        systemctl restart purpledeck-mesh.service 2>/dev/null && \
            ok "purpledeck-mesh restarted" || \
            warn "purpledeck-mesh restart failed — check: journalctl -u purpledeck-mesh"
    else
        warn "purpledeck-mesh.service not enabled — enabling"
        systemctl enable purpledeck-mesh.service 2>/dev/null || true
        systemctl start  purpledeck-mesh.service 2>/dev/null || true
    fi

    log "Waiting for bat0 and $PD_MESH_IF (up to 30s)..."
    waited=0
    while [ "$waited" -lt 30 ]; do
        ip link show bat0 &>/dev/null && ip link show "$PD_MESH_IF" &>/dev/null && \
            { ok "Mesh interfaces up"; break; }
        sleep 2; waited=$((waited+2))
    done
    [ "$waited" -ge 30 ] && warn "Mesh interfaces not up after 30s"

    stage_done 10; ok "Stage 10 done"
fi

# =============================================================================
# STAGE 11 — PEERING VERIFICATION
# =============================================================================
section "Stage 11: Mesh Peering"

if ! stage_complete 11; then
    log "Waiting up to 60s for peers..."
    waited=0; found=0
    while [ "$waited" -lt 60 ]; do
        count=$(batctl meshif bat0 n 2>/dev/null | grep -c ':' || echo 0)
        if [ "$count" -gt 0 ]; then
            found=1; ok "Peers detected:"
            batctl meshif bat0 n 2>/dev/null || true
            # Add peers to known-nodes
            batctl meshif bat0 n 2>/dev/null | grep ':' | awk '{print $1}' | while read mac; do
                log "  Peer MAC on mesh: $mac"
            done
            break
        fi
        sleep 5; waited=$((waited+5))
        log "  No peers yet... ${waited}s"
    done

    if [ "$found" -eq 0 ]; then
        warn "No peers found after 60s"
        warn "  HaLow: $(ip -br link show "$PD_MESH_IF" 2>/dev/null || echo missing)"
        warn "  bat0:  $(ip -br link show bat0 2>/dev/null || echo missing)"
        warn "  TX:    $(cat /sys/class/net/"$PD_MESH_IF"/statistics/tx_bytes 2>/dev/null || echo N/A)"
        warn "  RX:    $(cat /sys/class/net/"$PD_MESH_IF"/statistics/rx_bytes 2>/dev/null || echo N/A)"
        iw dev "$PD_MESH_IF" info 2>/dev/null | grep -E 'type|channel|txpower' || true
        warn "  Next: iw event on both nodes simultaneously"
        warn "  Next: batctl meshif bat0 o (wait 2-3 min)"
    fi

    stage_done 11; ok "Stage 11 done"
fi

# =============================================================================
# STAGE 12 — FINALIZE
# =============================================================================
section "Stage 12: Finalizing"

mkdir -p "$PD_STATE"
{
    echo "completed=$(date -Iseconds)"
    echo "username=$PD_USERNAME"
    echo "hostname=$SESSION_HOSTNAME"
    echo "combined=${PD_USERNAME}-${SESSION_HOSTNAME}"
    echo "role=$PD_ROLE"
    echo "halow=${PD_MESH_IF:-MISSING}"
    echo "uplink=$PD_UPLINK_IF"
    echo "kernel=$(uname -r)"
} > "$PD_FIRSTBOOT_DONE"

systemctl restart avahi-daemon 2>/dev/null || true

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║        PurpleDeck First-Boot Complete (v2)             ║"
echo "╠════════════════════════════════════════════════════════╣"
printf "║  Username    : %-40s ║\n" "$PD_USERNAME"
printf "║  Session ID  : %-40s ║\n" "$SESSION_HOSTNAME"
printf "║  Permanent   : %-40s ║\n" "${PD_USERNAME}-${SESSION_HOSTNAME}.local"
printf "║  Role        : %-40s ║\n" "$PD_ROLE"
printf "║  HaLow       : %-40s ║\n" "${PD_MESH_IF:-MISSING}"
printf "║  Uplink      : %-40s ║\n" "$PD_UPLINK_IF"
printf "║  AP SSID     : %-40s ║\n" "$AP_SSID"
printf "║  Mesh ID     : %-40s ║\n" "$DEFAULT_MESH_ID"
echo "╠════════════════════════════════════════════════════════╣"
echo "║  Web UI : http://${PD_USERNAME}-${SESSION_HOSTNAME}.local:8080"
echo "║  Status : sudo bash pd-firstboot.sh --status           ║"
echo "║  Repair : sudo bash pd-firstboot.sh --repair           ║"
echo "║  Log    : /var/log/pd-firstboot.log                    ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

log "Complete — ${PD_USERNAME}-${SESSION_HOSTNAME} ($PD_ROLE)"
exit 0

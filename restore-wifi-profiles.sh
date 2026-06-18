#!/bin/bash
# restore-wifi-profiles.sh
# Re-adds the upstream wifi profiles to NetworkManager and frees wlan0
# temporarily so they can be configured. Mesh is restarted at the end.
#
# NOTE: With the current purpledeck-mesh.sh, wlan0 will be re-captured by
# hostapd after the mesh restarts, so autoconnect to upstream wifi will
# only work until the mesh service comes back up. To get true concurrent
# AP+STA on wlan0 (mesh AP + upstream uplink at the same time),
# purpledeck-mesh.sh needs to be rewritten — see the first-boot-orchestrator
# spec doc for the proper fix.
#
# For now, this script restores the profiles so they exist, lets you
# briefly connect to upstream wifi during the window before mesh restarts,
# and leaves the mesh running afterward.

set -e
[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }

echo "[1/5] Stopping purpledeck-mesh TEMPORARILY so wlan0 is freed"
echo "      (mesh will be restarted at the end)"
MESH_WAS_RUNNING=0
if systemctl is-active purpledeck-mesh >/dev/null 2>&1; then
  MESH_WAS_RUNNING=1
  systemctl stop purpledeck-mesh
fi
sleep 2

echo "[2/5] Telling NetworkManager to manage wlan0"
nmcli device set wlan0 managed yes 2>/dev/null || true
sleep 2

echo "[3/5] Adding upstream wifi profiles (you will be prompted for passwords)"

add_profile() {
  local SSID="$1"
  local PRIO="$2"

  if nmcli connection show "$SSID" &>/dev/null; then
    echo "    [$SSID] already exists, ensuring autoconnect=yes and priority=$PRIO"
    nmcli connection modify "$SSID" connection.autoconnect yes
    nmcli connection modify "$SSID" connection.autoconnect-priority "$PRIO"
    return
  fi

  read -s -p "    Password for $SSID (leave blank to skip): " PASS
  echo ""
  if [ -z "$PASS" ]; then
    echo "    [$SSID] skipped"
    return
  fi

  nmcli connection add type wifi con-name "$SSID" ifname wlan0 ssid "$SSID" \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" \
    connection.autoconnect yes \
    connection.autoconnect-priority "$PRIO"
  echo "    [$SSID] added with priority $PRIO"
}

add_profile "have-you-ever" 40
add_profile "ramjam" 30
add_profile "slammin-clam" 20
add_profile "clam" 10

echo "[4/5] Triggering wifi rescan"
nmcli device wifi rescan 2>/dev/null || true
sleep 3
nmcli device wifi list 2>/dev/null || true

echo ""
echo "[5/5] Restarting purpledeck-mesh"
if [ "$MESH_WAS_RUNNING" -eq 1 ]; then
  systemctl start purpledeck-mesh
  sleep 3
  if systemctl is-active purpledeck-mesh >/dev/null 2>&1; then
    echo "    Mesh restarted successfully."
  else
    echo "    WARNING: mesh failed to restart. Check 'systemctl status purpledeck-mesh'."
  fi
else
  echo "    Mesh was not running before this script, leaving it stopped."
fi

echo ""
echo "===== DONE ====="
echo ""
echo "Profiles are now persisted and will autoconnect on future boots BEFORE"
echo "the mesh service starts. Once the mesh service starts, it will reclaim"
echo "wlan0 and the upstream connection will drop. This is a known limitation"
echo "of the current purpledeck-mesh.sh — the proper fix (concurrent AP+STA)"
echo "is in the first-boot-orchestrator spec for the next implementation pass."
echo ""
echo "To temporarily get on upstream wifi without the mesh hogging wlan0:"
echo "    sudo systemctl stop purpledeck-mesh"
echo "    sudo nmcli connection up have-you-ever"
echo ""
echo "To restart mesh later:"
echo "    sudo systemctl start purpledeck-mesh"

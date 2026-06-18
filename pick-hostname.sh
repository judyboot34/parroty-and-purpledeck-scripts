#!/bin/bash
# pick-hostname.sh
# Detects this device's hardware and picks a unique hostname based on the mesh.
#
# Naming scheme:
#   Pi 5 / 500 / 4 / 400 -> commander<RAM_GB>  (e.g. commander16, commander8)
#   Pi Zero              -> hoodlum
#   Pi Zero 2W           -> hoodlum2w
#
# Collision suffix: first instance is bare, subsequent are _2, _3, _4...
#
# USAGE:
#   pick-hostname.sh              # prints the chosen name to stdout
#   pick-hostname.sh --apply      # prints AND applies via hostnamectl (requires root)
#
# Exits with non-zero on detection failure so a caller can fall back.

set -e

# ---------- 1. Detect hardware ----------
MODEL_FILE="/proc/device-tree/model"
if [ ! -r "$MODEL_FILE" ]; then
  echo "ERROR: cannot read $MODEL_FILE" >&2
  exit 1
fi

# device-tree model strings are NUL-terminated; strip the NUL
MODEL=$(tr -d '\0' < "$MODEL_FILE")

# ---------- 2. Pick prefix ----------
PREFIX=""
case "$MODEL" in
  *"Pi 5"*|*"Pi 500"*|*"Pi 4"*|*"Pi 400"*)
    # commander<RAM>
    # MemTotal is in KB; convert to GB and round to nearest power of 2
    MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    MEM_GB=$(( (MEM_KB + 524288) / 1048576 ))  # round to nearest GB

    # Snap to canonical Pi RAM sizes: 1, 2, 4, 8, 16
    case "$MEM_GB" in
      0|1)    RAM=1  ;;
      2)      RAM=2  ;;
      3|4|5)  RAM=4  ;;
      6|7|8|9|10) RAM=8 ;;
      *)      RAM=16 ;;
    esac
    PREFIX="commander${RAM}"
    ;;
  *"Pi Zero 2"*)
    PREFIX="hoodlum2w"
    ;;
  *"Pi Zero"*)
    PREFIX="hoodlum"
    ;;
  *)
    echo "ERROR: unrecognized hardware model: $MODEL" >&2
    exit 2
    ;;
esac

# ---------- 3. Scan mesh for existing hostnames ----------
# Use avahi-browse to list every .local host announcing itself.
# Resolve mode (-r) is needed so we get hostnames, not just service names.
# -t = terminate after one pass, -p = parseable, -a = all types
# Falls back gracefully if avahi isn't running yet.
EXISTING_NAMES=""
if command -v avahi-browse >/dev/null 2>&1; then
  EXISTING_NAMES=$(timeout 12 avahi-browse -rpt _workstation._tcp 2>/dev/null \
    | awk -F';' '$1=="=" {print $7}' \
    | sed 's/\.local$//' \
    | sort -u)
fi

# Also include this node's own current hostname so we don't accidentally
# collide with ourselves if we already had a temporary name.
CURRENT_HOST=$(hostname)
EXISTING_NAMES=$(printf "%s\n%s\n" "$EXISTING_NAMES" "$CURRENT_HOST" | sort -u | grep -v '^$' || true)

# ---------- 4. Find next-available suffix ----------
# We look for hostnames that match the prefix EXACTLY or with _N suffix.
# If "commander16" is taken, try commander16_2, _3, etc.
pick_name() {
  local base="$1"
  if ! echo "$EXISTING_NAMES" | grep -qx "$base"; then
    echo "$base"
    return
  fi
  local n=2
  while echo "$EXISTING_NAMES" | grep -qx "${base}_${n}"; do
    n=$((n + 1))
    if [ "$n" -gt 999 ]; then
      echo "ERROR: too many collisions for $base" >&2
      exit 3
    fi
  done
  echo "${base}_${n}"
}

CHOSEN=$(pick_name "$PREFIX")

# ---------- 5. Output / apply ----------
if [ "${1:-}" = "--apply" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: --apply requires root" >&2
    exit 4
  fi
  hostnamectl set-hostname "$CHOSEN"
  # Also update /etc/hosts so local resolution works
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$CHOSEN/" /etc/hosts
  else
    echo -e "127.0.1.1\t$CHOSEN" >> /etc/hosts
  fi
  echo "Applied hostname: $CHOSEN" >&2
fi

echo "$CHOSEN"

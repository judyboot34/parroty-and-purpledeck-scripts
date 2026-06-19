#!/bin/bash
# deploy-webui.sh
# Deploy web UI files to /opt/purpledeck-gui from one of two sources:
#   - flash drive (default):  /mnt/flash/purpledeck-gui-edit
#   - github repo:            via gh CLI, clones/pulls and uses webui/ subfolder
#
# Backs up current install, copies new files, restarts service.
# Auto-rollback on failed restart.
#
# Usage:
#   sudo bash deploy-webui.sh                # from flash drive
#   sudo bash deploy-webui.sh --from-flash   # explicit flash mode
#   sudo bash deploy-webui.sh --from-repo    # pull latest from GitHub

set -e
[ "$(id -u)" -eq 0 ] || { echo "must be root: sudo bash $0 [--from-flash|--from-repo]"; exit 1; }

# ---------- Config ----------
REPO_URL="https://github.com/judyboot34/parroty-and-purpledeck-scripts"
REPO_LOCAL="${REPO_LOCAL:-/home/pi/parroty-and-purpledeck-scripts}"
REPO_SUBDIR="webui"
FLASH_SRC="/mnt/flash/purpledeck-gui-edit"
DST="/opt/purpledeck-gui"
BACKUP="/opt/purpledeck-gui.backup-$(date +%Y%m%d-%H%M%S)"

# ---------- Pick source ----------
MODE="${1:---from-flash}"

case "$MODE" in
  --from-flash)
    SRC="$FLASH_SRC"
    echo "Source: flash drive ($SRC)"
    ;;
  --from-repo)
    if ! command -v gh >/dev/null 2>&1; then
      echo "ERROR: GitHub CLI (gh) not installed. Install with: sudo apt install gh"
      exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
      echo "ERROR: gh not authenticated. Run: gh auth login"
      exit 1
    fi
    if [ ! -d "$REPO_LOCAL/.git" ]; then
      echo "Cloning repo to $REPO_LOCAL..."
      mkdir -p "$(dirname "$REPO_LOCAL")"
      gh repo clone "$REPO_URL" "$REPO_LOCAL"
    else
      echo "Pulling latest from $REPO_URL..."
      cd "$REPO_LOCAL"
      git pull --rebase
    fi
    SRC="$REPO_LOCAL/$REPO_SUBDIR"
    echo "Source: GitHub repo ($SRC)"
    ;;
  *)
    echo "Usage: $0 [--from-flash|--from-repo]"
    exit 1
    ;;
esac

if [ ! -d "$SRC" ]; then
  echo "ERROR: source dir $SRC not found."
  if [ "$MODE" = "--from-flash" ]; then
    echo "Did you copy the working tree to the flash drive?"
    echo "On the Pi:  sudo cp -r /opt/purpledeck-gui /mnt/flash/purpledeck-gui-edit"
  fi
  exit 1
fi

# ---------- Deploy ----------
echo ""
echo "[1/5] Backing up current install to $BACKUP"
cp -a "$DST" "$BACKUP"

echo "[2/5] Stopping purpledeck-gui service"
systemctl stop purpledeck-gui 2>/dev/null || true

echo "[3/5] Copying new files into place"
rsync -a --delete \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='.venv' \
  --exclude='venv' \
  "$SRC/" "$DST/"

echo "[4/5] Setting ownership and permissions"
chown -R root:root "$DST"
find "$DST" -name "*.py" -exec chmod 644 {} \;
find "$DST" -name "*.sh" -exec chmod 755 {} \;
chmod -R a+r "$DST"

echo "[5/5] Starting purpledeck-gui service"
systemctl start purpledeck-gui
sleep 2

if systemctl is-active purpledeck-gui >/dev/null 2>&1; then
  echo ""
  echo "===== DEPLOY SUCCESSFUL ====="
  echo "Service is running. Check logs with:"
  echo "    sudo journalctl -u purpledeck-gui -f"
  echo ""
  echo "Backup kept at: $BACKUP"
  echo "(safe to delete if everything looks good)"
  echo ""
  echo "To manually restore:"
  echo "    sudo rm -rf $DST"
  echo "    sudo cp -a $BACKUP $DST"
  echo "    sudo systemctl restart purpledeck-gui"
else
  echo ""
  echo "===== DEPLOY FAILED ====="
  echo "Service did not start. Logs:"
  echo ""
  journalctl -u purpledeck-gui -n 30 --no-pager
  echo ""
  echo "Auto-restoring backup..."
  rm -rf "$DST"
  cp -a "$BACKUP" "$DST"
  systemctl start purpledeck-gui
  if systemctl is-active purpledeck-gui >/dev/null 2>&1; then
    echo "Backup restored. Service is back online with previous version."
  else
    echo "WARNING: even the backup failed to start. Manual intervention needed."
  fi
  exit 1
fi

#!/bin/bash
# push-webui-to-repo.sh
# Snapshot the current /opt/purpledeck-gui and push to GitHub.
#
# Assumes:
#   - GitHub CLI (`gh`) is installed and authenticated (`gh auth login` done once)
#   - The local clone of the repo lives at $REPO_LOCAL (configurable below)
#   - The webui files live under the repo's webui/ folder
#
# Usage:
#   sudo bash push-webui-to-repo.sh                 # interactive commit message
#   sudo bash push-webui-to-repo.sh "fix bat0 bug"  # commit with given message

set -e

# ---------- Config ----------
REPO_URL="https://github.com/judyboot34/parroty-and-purpledeck-scripts"
REPO_LOCAL="${REPO_LOCAL:-/home/pi/parroty-and-purpledeck-scripts}"
REPO_SUBDIR="webui"
SRC="/opt/purpledeck-gui"

# ---------- Sanity checks ----------
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI (gh) is not installed."
  echo "Install with:  sudo apt install gh"
  echo "Then authenticate:  gh auth login"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh is not authenticated."
  echo "Run:  gh auth login"
  exit 1
fi

if [ ! -d "$SRC" ]; then
  echo "ERROR: source dir $SRC not found."
  exit 1
fi

# ---------- Get or update the local clone ----------
if [ ! -d "$REPO_LOCAL/.git" ]; then
  echo "[1/5] No local clone found at $REPO_LOCAL. Cloning..."
  mkdir -p "$(dirname "$REPO_LOCAL")"
  gh repo clone "$REPO_URL" "$REPO_LOCAL"
else
  echo "[1/5] Pulling latest from origin..."
  cd "$REPO_LOCAL"
  git pull --rebase || {
    echo "WARNING: git pull failed. You may have local changes that conflict."
    echo "Resolve manually, then re-run this script."
    exit 1
  }
fi

# ---------- Copy the UI files into the repo ----------
echo "[2/5] Copying $SRC -> $REPO_LOCAL/$REPO_SUBDIR/"
mkdir -p "$REPO_LOCAL/$REPO_SUBDIR"
# rsync with --delete so removed files actually leave the repo
rsync -a --delete \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='.venv' \
  --exclude='venv' \
  "$SRC/" "$REPO_LOCAL/$REPO_SUBDIR/"

# ---------- Diff check ----------
cd "$REPO_LOCAL"
if [ -z "$(git status --porcelain "$REPO_SUBDIR")" ]; then
  echo ""
  echo "===== No changes to push ====="
  echo "Local UI matches what's already in the repo."
  exit 0
fi

echo "[3/5] Changes detected:"
git status --short "$REPO_SUBDIR"

# ---------- Commit ----------
if [ -n "${1:-}" ]; then
  COMMIT_MSG="$1"
else
  echo ""
  read -p "Commit message (or press Enter for auto-message): " COMMIT_MSG
  if [ -z "$COMMIT_MSG" ]; then
    COMMIT_MSG="webui: snapshot from $(hostname) at $(date +%Y-%m-%d\ %H:%M)"
  fi
fi

echo "[4/5] Committing..."
git add "$REPO_SUBDIR"
git -c user.email="purpledeck@$(hostname).local" \
    -c user.name="PurpleDeck Push ($(hostname))" \
    commit -m "$COMMIT_MSG"

# ---------- Push ----------
echo "[5/5] Pushing to origin..."
git push origin HEAD

echo ""
echo "===== PUSHED SUCCESSFULLY ====="
echo "Commit: $COMMIT_MSG"
echo "View at: $REPO_URL"

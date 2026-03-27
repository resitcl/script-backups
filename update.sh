#!/usr/bin/env bash
# update.sh — pull latest changes and redeploy scripts + services.
#
# Usage:  sudo bash update.sh [install-dir]
#   install-dir  default: /opt/db-backups
#
# This script copies the updated scripts into the install directory,
# reloads the systemd unit, and restarts the status server.
# It does NOT touch .env or the cron schedule — those are only set by install.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${1:-/opt/db-backups}"

echo "Updating ${INSTALL_DIR} from ${SCRIPT_DIR} ..."

# ── Pull latest (only if we're in a git repo) ────────────────────────────────
if [[ -d "${SCRIPT_DIR}/.git" ]] || git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null; then
  echo "Pulling latest changes ..."
  git -C "$SCRIPT_DIR" pull --ff-only
fi

# ── Copy scripts ─────────────────────────────────────────────────────────────
cp "${SCRIPT_DIR}/backup.sh" \
   "${SCRIPT_DIR}/status-server.sh" \
   "${SCRIPT_DIR}/status-server.service" \
   "${SCRIPT_DIR}/.env.example" \
   "$INSTALL_DIR/"

chmod +x "${INSTALL_DIR}/backup.sh" "${INSTALL_DIR}/status-server.sh"

echo "Scripts updated."

# ── Reload systemd unit ──────────────────────────────────────────────────────
UNIT_FILE="/etc/systemd/system/backup-status-server.service"
sed "s|/opt/db-backups|${INSTALL_DIR}|g" \
  "${INSTALL_DIR}/status-server.service" > "$UNIT_FILE"

systemctl daemon-reload
systemctl restart backup-status-server
echo "Status server restarted."

echo ""
echo "Update complete. .env and cron schedule were NOT modified."
echo "To change the cron schedule, re-run:  sudo bash install.sh \"0 5 * * *\""

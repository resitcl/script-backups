#!/usr/bin/env bash
# install.sh — deploy scripts to /opt/db-backups, register cron job and
#              systemd service for the status server.
#
# Usage:  sudo bash install.sh [cron-schedule] [install-dir]
#   cron-schedule  default: "0 2 * * *"  (daily 02:00 UTC)
#   install-dir    default: /opt/db-backups
set -euo pipefail

CRON_SCHEDULE="${1:-0 2 * * *}"
INSTALL_DIR="${2:-/opt/db-backups}"

echo "Installing to ${INSTALL_DIR} ..."
mkdir -p "$INSTALL_DIR"

cp backup.sh status-server.sh status-server.service .env.example "$INSTALL_DIR/"
chmod +x "${INSTALL_DIR}/backup.sh" "${INSTALL_DIR}/status-server.sh"

# Only create .env from example if it does not exist yet
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  cp .env.example "${INSTALL_DIR}/.env"
  echo ""
  echo ">>> IMPORTANT: edit ${INSTALL_DIR}/.env before the first run:"
  echo "      S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
  echo ""
fi

# ── Cron ─────────────────────────────────────────────────────────────────────
CRON_FILE="/etc/cron.d/db-backups"
cat > "$CRON_FILE" <<EOF
# DB backup — managed by install.sh
# Format: min hour day month weekday root command
${CRON_SCHEDULE} root ${INSTALL_DIR}/backup.sh >> /var/log/db-backup.log 2>&1
EOF
chmod 644 "$CRON_FILE"
echo "Cron registered:  ${CRON_FILE}  (${CRON_SCHEDULE})"

# ── Systemd status server ─────────────────────────────────────────────────────
UNIT_FILE="/etc/systemd/system/backup-status-server.service"
sed "s|/opt/db-backups|${INSTALL_DIR}|g" \
  "${INSTALL_DIR}/status-server.service" > "$UNIT_FILE"

systemctl daemon-reload
systemctl enable --now backup-status-server
echo "Status server:    systemctl status backup-status-server  (port 8099)"

echo ""
echo "Installation complete."
echo "Run a manual test with:  ${INSTALL_DIR}/backup.sh"

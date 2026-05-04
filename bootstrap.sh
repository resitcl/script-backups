#!/usr/bin/env bash
# bootstrap.sh — one-command installer / updater for db-backups.
#
# Usage (fresh install):
#   curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash
#
# Usage (pre-set cron schedule, skip that prompt):
#   curl -sSL .../bootstrap.sh | sudo bash -s -- "0 3 * * *" /opt/db-backups
#
# Re-run to update scripts without touching .env or cron.
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/USER/REPO/main"
CRON_ARG="${1:-}"
INSTALL_DIR="${2:-/opt/db-backups}"

FILES=(backup.sh status-server.sh status-server.service .env.example install.sh)

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Run as root.  sudo bash, or:  curl ... | sudo bash" >&2
  exit 1
fi

# ── Tmpdir (auto-removed on exit) ─────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Download files from GitHub raw ────────────────────────────────────────────
echo "Downloading scripts from GitHub..."
for f in "${FILES[@]}"; do
  if ! curl -fsSL "${REPO_RAW}/${f}" -o "${WORK_DIR}/${f}"; then
    echo "ERROR: Failed to download ${f} from ${REPO_RAW}/${f}" >&2
    exit 1
  fi
done
chmod +x "${WORK_DIR}/backup.sh" "${WORK_DIR}/status-server.sh" "${WORK_DIR}/install.sh"
echo "Download complete."

# ── Fresh install vs update ───────────────────────────────────────────────────
FRESH=false
[[ ! -f "${INSTALL_DIR}/.env" ]] && FRESH=true

if $FRESH; then

  _prompt_required() {
    local label="$1" value=""
    while [[ -z "$value" ]]; do
      read -rp "  ${label}: " value </dev/tty
    done
    printf '%s' "$value"
  }

  _prompt_optional() {
    local label="$1" default="$2" value
    read -rp "  ${label} [${default}]: " value </dev/tty
    printf '%s' "${value:-$default}"
  }

  [[ ! -e /dev/tty ]] && { echo "ERROR: No terminal available for interactive prompts. Pre-create ${INSTALL_DIR}/.env to skip prompts." >&2; exit 1; }
  echo ""
  echo "=== db-backups: first-time configuration ==="

  S3_BUCKET="$(_prompt_required    'S3 bucket name')"
  AWS_ACCESS_KEY_ID="$(_prompt_required 'AWS Access Key ID')"
  read -rsp "  AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY </dev/tty; echo
  [[ -z "$AWS_SECRET_ACCESS_KEY" ]] && { echo "ERROR: AWS Secret Access Key is required." >&2; exit 1; }
  AWS_DEFAULT_REGION="$(_prompt_optional 'AWS region'        'us-east-1')"
  S3_RETENTION_DAYS="$(_prompt_optional  'Retention days'    '30')"

  if [[ -n "$CRON_ARG" ]]; then
    CRON_SCHEDULE="$CRON_ARG"
    echo "  Cron schedule: ${CRON_SCHEDULE}  (from argument)"
  else
    CRON_SCHEDULE="$(_prompt_optional 'Cron schedule (UTC)' '0 5 * * *')"
  fi
  echo ""

else
  # ── Update path: read existing cron schedule ──────────────────────────────
  CRON_FILE="/etc/cron.d/db-backups"
  if [[ -f "$CRON_FILE" ]]; then
    _raw_cron="$(grep -v '^#' "$CRON_FILE" | grep -v '^[[:space:]]*$' | head -1)"
    _sched="$(awk '{print $1" "$2" "$3" "$4" "$5}' <<< "$_raw_cron" 2>/dev/null || true)"
    if [[ "$_sched" =~ ^[0-9\*/,-] ]]; then
      CRON_SCHEDULE="$_sched"
    else
      CRON_SCHEDULE="${CRON_ARG:-0 5 * * *}"
    fi
  else
    CRON_SCHEDULE="${CRON_ARG:-0 5 * * *}"
  fi
  echo "Updating existing installation in ${INSTALL_DIR}..."
  echo "Cron schedule preserved: ${CRON_SCHEDULE}"
fi

# ── Delegate to install.sh ────────────────────────────────────────────────────
# Pre-create INSTALL_DIR and a placeholder .env so install.sh skips its
# "edit .env" message — bootstrap writes the real credentials below.
mkdir -p "$INSTALL_DIR"
$FRESH && touch "${INSTALL_DIR}/.env"
bash "${WORK_DIR}/install.sh" "$CRON_SCHEDULE" "$INSTALL_DIR"

# ── Write .env with real credentials (fresh install only) ─────────────────────
if $FRESH; then
  _env_tmp="$(mktemp -p "$INSTALL_DIR")"
  chmod 600 "$_env_tmp"
  cat > "$_env_tmp" <<EOF
S3_BUCKET=${S3_BUCKET}
S3_PREFIX=db-backups
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
BACKUP_TMP_DIR=/tmp/db-backups
S3_RETENTION_DAYS=${S3_RETENTION_DAYS}
STATUS_FILE=/var/www/backup-status/status.json
EOF
  mv "$_env_tmp" "${INSTALL_DIR}/.env"
  echo "Credentials written to ${INSTALL_DIR}/.env"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "$SERVER_IP" ]] && SERVER_IP="<server-ip>"
echo ""
echo "============================================="
echo "  db-backups ready"
echo "  Install dir:    ${INSTALL_DIR}"
echo "  Cron schedule:  ${CRON_SCHEDULE} (UTC)"
echo "  Status:         http://${SERVER_IP}:8099/status"
echo "  Manual test:    ${INSTALL_DIR}/backup.sh"
echo "  Logs:           tail -f /var/log/db-backup.log"
echo "============================================="

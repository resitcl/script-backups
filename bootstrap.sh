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
      read -rp "  ${label}: " value
    done
    printf '%s' "$value"
  }

  _prompt_optional() {
    local label="$1" default="$2" value
    read -rp "  ${label} [${default}]: " value
    printf '%s' "${value:-$default}"
  }

  echo ""
  echo "=== db-backups: first-time configuration ==="

  S3_BUCKET="$(_prompt_required    'S3 bucket name')"
  AWS_ACCESS_KEY_ID="$(_prompt_required 'AWS Access Key ID')"
  read -rsp "  AWS Secret Access Key: " AWS_SECRET_ACCESS_KEY; echo
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
  if [[ -f "$CRON_FILE" ]] && grep -qv '^#' "$CRON_FILE" 2>/dev/null; then
    CRON_SCHEDULE="$(grep -v '^#' "$CRON_FILE" | head -1 | awk '{print $1" "$2" "$3" "$4" "$5}')"
  else
    CRON_SCHEDULE="${CRON_ARG:-0 5 * * *}"
  fi
  echo "Updating existing installation in ${INSTALL_DIR}..."
  echo "Cron schedule preserved: ${CRON_SCHEDULE}"
fi

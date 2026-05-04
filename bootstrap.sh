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

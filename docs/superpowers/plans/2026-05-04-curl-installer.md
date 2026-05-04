# Curl Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `bootstrap.sh` so any server can install the backup service with one `curl | bash` command — no git, no SSH keys.

**Architecture:** A new `bootstrap.sh` downloads the 5 required files from GitHub raw to a tmpdir, prompts for config on fresh installs, then delegates to the existing unchanged `install.sh`. Re-running the same curl command performs an update without touching `.env` or the cron schedule.

**Tech Stack:** Bash, curl, systemd, cron — no new dependencies.

> **Before starting:** Replace `USER/REPO` in `bootstrap.sh` with your actual GitHub username and repo name before pushing.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `bootstrap.sh` | CREATE | Download files, prompt config, delegate to install.sh |
| `.gitignore` | CREATE | Prevent accidental `.env` commit |
| `README.md` | MODIFY | Replace git clone instructions with curl command |
| All other files | UNCHANGED | — |

---

### Task 1: Add .gitignore

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create .gitignore**

```
.env
```

File path: `/Users/favio/code/bash/script-backups/.gitignore`

- [ ] **Step 2: Verify git no longer tracks .env (if it existed)**

```bash
git status
```

Expected: `.gitignore` shows as untracked. `.env` does NOT appear.

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore to protect .env from accidental commit"
```

---

### Task 2: bootstrap.sh — scaffold + root check + args + tmpdir

**Files:**
- Create: `bootstrap.sh`

- [ ] **Step 1: Create bootstrap.sh with header, constants, root check, arg parsing, tmpdir**

```bash
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
```

- [ ] **Step 2: Verify script parses without errors**

```bash
bash -n bootstrap.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: add bootstrap.sh scaffold with root check and tmpdir"
```

---

### Task 3: bootstrap.sh — download logic

**Files:**
- Modify: `bootstrap.sh` (append after tmpdir block)

- [ ] **Step 1: Add download section**

Append to `bootstrap.sh` after the tmpdir block:

```bash
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
```

- [ ] **Step 2: Syntax check**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: add file download logic to bootstrap.sh"
```

---

### Task 4: bootstrap.sh — fresh install prompts

**Files:**
- Modify: `bootstrap.sh` (append after download block)

- [ ] **Step 1: Add fresh-vs-update detection and prompts**

Append to `bootstrap.sh`:

```bash
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
```

- [ ] **Step 2: Syntax check**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: add interactive prompts and fresh/update detection to bootstrap.sh"
```

---

### Task 5: bootstrap.sh — install.sh call + write .env + summary

**Files:**
- Modify: `bootstrap.sh` (append final block)

- [ ] **Step 1: Add install delegation, .env write, and summary**

Append to `bootstrap.sh`:

```bash
# ── Delegate to install.sh ────────────────────────────────────────────────────
bash "${WORK_DIR}/install.sh" "$CRON_SCHEDULE" "$INSTALL_DIR"

# ── Write .env with real credentials (fresh install only) ─────────────────────
if $FRESH; then
  cat > "${INSTALL_DIR}/.env" <<EOF
S3_BUCKET=${S3_BUCKET}
S3_PREFIX=db-backups
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}
BACKUP_TMP_DIR=/tmp/db-backups
S3_RETENTION_DAYS=${S3_RETENTION_DAYS}
STATUS_FILE=/var/www/backup-status/status.json
EOF
  chmod 600 "${INSTALL_DIR}/.env"
  echo "Credentials written to ${INSTALL_DIR}/.env"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
echo ""
echo "============================================="
echo "  db-backups ready"
echo "  Install dir:    ${INSTALL_DIR}"
echo "  Cron schedule:  ${CRON_SCHEDULE} (UTC)"
echo "  Status:         http://${SERVER_IP}:8099/status"
echo "  Manual test:    ${INSTALL_DIR}/backup.sh"
echo "  Logs:           tail -f /var/log/db-backup.log"
echo "============================================="
```

- [ ] **Step 2: Final syntax check**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 3: Make bootstrap.sh executable**

```bash
chmod +x bootstrap.sh
```

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: complete bootstrap.sh with install delegation, .env write, and summary"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Installation section**

Find the `## Installation` section in `README.md` (around line 148). Replace the existing content with:

```markdown
## Installation

### One-command install (recommended)

```bash
curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash
```

The installer will prompt for S3 credentials and cron schedule, then configure cron and systemd automatically.

**To pre-set the cron schedule** (skips that prompt):

```bash
curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash -s -- "0 3 * * *"
```

### Update

Re-run the same curl command. Your `.env` and cron schedule are preserved — only the scripts are updated.

```bash
curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash
```

### Manual install (from a local clone)

```bash
git clone https://github.com/USER/REPO.git /tmp/db-backups-src
cd /tmp/db-backups-src
cp .env.example .env
nano .env   # fill in S3 credentials
sudo bash install.sh "0 5 * * *"
```
```

- [ ] **Step 2: Verify README renders correctly**

```bash
grep -n "curl" README.md
```

Expected: lines showing the curl commands.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README with curl installer instructions"
```

---

### Task 7: Set real GitHub URL + push

**Files:**
- Modify: `bootstrap.sh` (replace placeholder)

- [ ] **Step 1: Replace USER/REPO with actual GitHub org/repo**

In `bootstrap.sh` line with `REPO_RAW=`, replace:

```bash
REPO_RAW="https://raw.githubusercontent.com/USER/REPO/main"
```

With your actual values, e.g.:

```bash
REPO_RAW="https://raw.githubusercontent.com/resit-cl/db-backups/main"
```

Do the same in `README.md` — replace all occurrences of `USER/REPO`.

- [ ] **Step 2: Syntax check**

```bash
bash -n bootstrap.sh
```

Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh README.md
git commit -m "chore: set real GitHub URL in bootstrap.sh and README"
```

- [ ] **Step 4: Make repo public on GitHub, then push**

```bash
git push origin main
```

- [ ] **Step 5: Verify raw URL is accessible**

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/bootstrap.sh | head -5
```

Expected: first 5 lines of `bootstrap.sh` printed.

---

### Task 8: Smoke test on a real server

> Run these on a test Linux server with Docker + AWS CLI installed.

- [ ] **Step 1: Fresh install test**

```bash
curl -sSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/bootstrap.sh | sudo bash
```

Expected:
- Prompts appear for S3 bucket, keys, region, retention, cron
- Scripts copied to `/opt/db-backups/`
- `/opt/db-backups/.env` has real values (not placeholders)
- `/etc/cron.d/db-backups` exists
- `systemctl status backup-status-server` shows `active (running)`
- `curl http://localhost:8099/status` returns JSON

- [ ] **Step 2: Verify .env has correct values**

```bash
cat /opt/db-backups/.env
```

Expected: real bucket name, real keys — not placeholders.

- [ ] **Step 3: Verify .env permissions**

```bash
stat -c '%a' /opt/db-backups/.env
```

Expected: `600`

- [ ] **Step 4: Manual backup run**

```bash
/opt/db-backups/backup.sh
```

Expected: exits 0 if DB containers found, logs to `/var/log/db-backup.log`.

- [ ] **Step 5: Update test (re-run curl)**

```bash
curl -sSL .../bootstrap.sh | sudo bash
```

Expected:
- No prompts shown
- "Updating existing installation" message
- Existing cron schedule preserved
- `.env` unchanged
- Status server restarted

- [ ] **Step 6: Verify .env unchanged after update**

```bash
grep S3_BUCKET /opt/db-backups/.env
```

Expected: same bucket name as entered during fresh install.

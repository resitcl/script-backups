# Curl Installer Design

## Goal

Run one command on any Linux server to install the backup service — no git, no SSH keys, no manual file copying.

```bash
curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash
```

Re-running the same command updates scripts without touching `.env` or the cron schedule.

---

## Files changed

| File | Change |
|---|---|
| `bootstrap.sh` | NEW — curl target, downloads + prompts + delegates |
| `.gitignore` | NEW — protects `.env` from accidental commit |
| All other files | UNCHANGED |

---

## Architecture

```
bootstrap.sh  (new, GitHub raw)
  ├── downloads 5 files from GitHub raw → tmpdir
  ├── fresh install → interactive prompts
  ├── update → reads existing cron from /etc/cron.d/db-backups
  ├── calls install.sh (unchanged)
  └── writes .env to INSTALL_DIR (fresh install only)
```

---

## bootstrap.sh flow

### Step 1 — root check
Exit immediately if not root. install.sh requires root for `/etc/cron.d` and systemd.

### Step 2 — parse args
```
$1  CRON_SCHEDULE  — pre-set schedule, skips only the cron prompt
$2  INSTALL_DIR    — default /opt/db-backups
```

### Step 3 — download to tmpdir
Download from `raw.githubusercontent.com/USER/REPO/main/`:
- `backup.sh`
- `status-server.sh`
- `status-server.service`
- `.env.example`
- `install.sh`

Fail fast if any download fails (network error, 404).

### Step 4 — detect fresh vs update

**Fresh install** (`INSTALL_DIR/.env` does not exist):

Prompt for each value. Required fields loop until non-empty. Optional fields show default in brackets.

| Prompt | Required | Default |
|---|---|---|
| S3 bucket name | yes | — |
| AWS Access Key ID | yes | — |
| AWS Secret Access Key | yes (silent) | — |
| AWS region | no | `us-east-1` |
| Retention days | no | `30` |
| Cron schedule | no | `0 5 * * *` |

**Update** (`INSTALL_DIR/.env` already exists):

Skip all prompts. Read cron schedule from `/etc/cron.d/db-backups` (parse the existing line) and pass it to install.sh. If cron file missing, fall back to default `0 5 * * *`.

### Step 5 — call install.sh

```bash
bash "${tmpdir}/install.sh" "$CRON_SCHEDULE" "$INSTALL_DIR"
```

install.sh is unchanged. It:
- Copies scripts to INSTALL_DIR
- Writes cron to `/etc/cron.d/db-backups`
- Enables + starts `backup-status-server` systemd service
- Copies `.env.example` → `.env` only if `.env` doesn't exist

### Step 6 — write .env (fresh install only)

After install.sh exits, overwrite `INSTALL_DIR/.env` with the prompted values.

install.sh already created `.env` from `.env.example` in step 5 — this step replaces it with real credentials.

### Step 7 — cleanup

`rm -rf "$tmpdir"`

Print summary: install dir, next backup time, status server port.

---

## Idempotency

| State | Behavior |
|---|---|
| First run | Prompts, installs, writes .env |
| Re-run, .env exists | No prompts, reads existing cron, updates scripts, restarts service |
| Re-run, cron file missing | Uses default schedule `0 5 * * *` |

`.env` is never overwritten on re-run. Cron and systemd are re-registered (install.sh behavior), but cron schedule is read from existing file so it doesn't regress.

---

## .gitignore

```
.env
```

Prevents accidental commit of real credentials.

---

## Usage examples

```bash
# Fresh install — prompts for S3 creds + cron schedule
curl -sSL https://raw.githubusercontent.com/USER/REPO/main/bootstrap.sh | sudo bash

# Fresh install — pre-set schedule, still prompts for S3 creds
curl -sSL .../bootstrap.sh | sudo bash -s -- "0 3 * * *" /opt/db-backups

# Update — re-run same command, no prompts (reads existing .env + cron)
curl -sSL .../bootstrap.sh | sudo bash
```

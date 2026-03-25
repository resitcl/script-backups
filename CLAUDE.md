# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A set of Bash scripts that run on a Linux server to back up all PostgreSQL, MySQL/MariaDB, and MongoDB containers to S3. There is no build step, no package manager, and no test suite — the scripts are deployed directly.

## Running the scripts

```bash
# Manual backup run (requires .env to exist)
./backup.sh

# Start the status HTTP server on the default port (8099)
./status-server.sh

# Install cron + systemd (requires root, runs on the target Linux server)
sudo bash install.sh "0 2 * * *"

# Follow live output from cron runs
tail -f /var/log/db-backup.log
```

## Architecture

`backup.sh` is the only script with real logic. Its execution flow:

1. **Autodiscovery** (`discover_and_backup`) — calls `docker ps` once and iterates every running container, matching on image name (`postgres*`, `mysql*`, `mariadb*`, `mongo*`, `mongodb*`).
2. **Credential extraction** — for each matched container, `container_env()` reads env vars via `docker inspect` (no passwords stored in config).
3. **Dump + compress** — runs the appropriate dump tool inside the container via `docker exec`, piping stdout directly to `gzip`. No uncompressed file is ever written to disk.
4. **S3 upload** — `upload_to_s3()` calls `aws s3 cp --storage-class STANDARD_IA`.
5. **Retention** (`apply_s3_retention`) — lists S3 objects older than `S3_RETENTION_DAYS` and deletes them.
6. **Status write** (`write_status`) — writes a single JSON file to `STATUS_FILE`. This is what `status-server.sh` serves.

`status-server.sh` is a self-contained Python 3 heredoc HTTP server embedded inside the bash script. It serves only `GET /status`, returning HTTP 200 when `overall == "success"` and 503 otherwise.

## Key conventions

- **Result tracking**: Four `declare -A` associative arrays (`RESULT_STATUS`, `RESULT_ERROR`, `RESULT_SIZE`, `RESULT_S3KEY`) accumulate results keyed by `"project::service"`. Call `record_ok` or `record_fail` — never set the arrays directly.
- **Non-fatal failures**: Every per-container backup call is suffixed with `|| true` so one failing DB never aborts the rest. `OVERALL` is set to `"failed"` by `record_fail` and never reset to `"success"`.
- **Image matching**: Done on the base name only (tag and registry prefix stripped). To add a new engine, add a case branch in `discover_and_backup` and a corresponding `backup_<engine>()` function following the existing pattern.
- **S3 path**: `{S3_PREFIX}/{project}/{db_type}/{TIMESTAMP}_{service}.{ext}` — project and service come from the `com.docker.compose.project` / `com.docker.compose.service` Docker labels, falling back to the container name.

## Config

`.env` (copied from `.env.example`) is the only config file. It holds S3 credentials and global settings. There is no per-project config — credentials are always read from the containers themselves at runtime.

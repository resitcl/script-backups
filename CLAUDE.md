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
5. **File storage** (`backup_all_filestores` → `backup_filestore`) — optional. Iterates the `FILESTORE_PATHS` env list (`name:/path;…`), `tar`+`gzip`s each directory and uploads to `{S3_PREFIX}/{name}/filestore/{TS}_{name}.tar.gz`. Root-owned paths (docker volumes) are read via passwordless `sudo`. Skipped entirely when `FILESTORE_PATHS` is empty.
6. **Retention** (`apply_s3_retention`) — lists S3 objects older than `S3_RETENTION_DAYS` and deletes them (covers both DB dumps and filestore tarballs — same prefix).
7. **Status write** (`write_status`) — writes a single JSON file to `STATUS_FILE`. This is what `status-server.sh` serves.

`status-server.sh` is a self-contained Python 3 heredoc HTTP server embedded inside the bash script. It serves only `GET /status`, returning HTTP 200 when `overall == "success"` and 503 otherwise.

## Key conventions

- **Result tracking**: Four `declare -A` associative arrays (`RESULT_STATUS`, `RESULT_ERROR`, `RESULT_SIZE`, `RESULT_S3KEY`) accumulate results keyed by `"project::service"` for databases and `"name::filestore"` for file storage. Call `record_ok` or `record_fail` — never set the arrays directly. `write_status` is generic over the keys, so new result types show up in the status JSON automatically.
- **Non-fatal failures**: Every per-container backup call is suffixed with `|| true` so one failing DB never aborts the rest. `OVERALL` is set to `"failed"` by `record_fail` and never reset to `"success"`.
- **Image matching**: Done on the base name only (tag and registry prefix stripped). To add a new engine, add a case branch in `discover_and_backup` and a corresponding `backup_<engine>()` function following the existing pattern.
- **S3 path**: `{S3_PREFIX}/{project}/{db_type}/{TIMESTAMP}_{service}.{ext}` — project and service come from the `com.docker.compose.project` / `com.docker.compose.service` Docker labels, falling back to the container name.
- **MongoDB port**: `backup_mongo` autodetects the port `mongod` listens on by reading `--port N` from the container's process (`/proc/1/cmdline`), falling back to `27017`. Set `MONGO_PORT` in `.env` to force a specific port. This is why a mongo container running on a non-default port (e.g. gestdoc's mongo on `27018`) backs up without any config.

## Config

`.env` (copied from `.env.example`) is the only config file. It holds S3 credentials and global settings. There is no per-project config — database credentials are always read from the containers themselves at runtime.

## Deployments

Each server is set up by SSH'ing in, cloning this repo with a GitHub **deploy key**, and running `install.sh`. SSH connection details for every Resit server live in `~/code/ssh_resit` and `~/resit_keys/servers.csv` (helper script `ssh_resit.sh` — pick a server by number). Do **not** commit AWS keys or `.env` files; the S3 secret is shared and is only ever copied server-to-server.

Per-server procedure (first install):

1. On the server, generate a dedicated key and register its public half as a **read-only deploy key** on `resitcl/script-backups`. A `~/.ssh/config` alias points git at it:
   ```
   Host github.com-scriptbackups
     HostName github.com
     IdentityFile ~/.ssh/id_ed25519_scriptbackups
     IdentitiesOnly yes
   ```
2. `git clone git@github.com-scriptbackups:resitcl/script-backups.git ~/script-backups`
3. `cd ~/script-backups && sudo bash install.sh "0 2 * * *"` — installs to `/opt/db-backups`, writes `/etc/cron.d/db-backups`, and enables the `backup-status-server` systemd unit (port 8099).
4. Fill `/opt/db-backups/.env`: copy the S3 credentials from an existing server's `/opt/db-backups/.env` (they are shared across the fleet) and set a **per-server `S3_PREFIX`** so backups don't collide in the bucket. Add `FILESTORE_PATHS` for any on-disk data (WordPress `wp-content`, upload dirs).
5. Validate: `sudo /opt/db-backups/backup.sh`, then `curl -s -o /dev/null -w '%{http_code}' localhost:8099/status` (expect `200`, i.e. last run `overall == success`).

To update an already-deployed server: `cd ~/script-backups && git pull && sudo cp backup.sh status-server.sh /opt/db-backups/` (re-running `install.sh` is also safe — it never overwrites an existing `.env`).

### Deployed servers

- **proyectos-prod-2** (Azure, `74.179.61.250`, `azureuser`, key `proyectos-prod-2_key.pem`, servers.csv #33)
  - S3: bucket `resit-prod-2026`, prefix `db-backups-prod-2` (S3 creds copied from proyectos-prod-1).
  - Databases (autodiscovered): `foroinnovacion/mysql`, `gestdoc-docker/mongo` (**port 27018**), `tiserx/postgres`.
  - Filestore: `wordpress-foroinnovacion` → foroinnovacion `wp-content` docker volume; `tiserx` → `/home/azureuser/tiserx/server/uploads`.
  - Schedule: daily 02:00. gestdoc's on-disk documents are intentionally **not** in `FILESTORE_PATHS` — they already live in the `gestdoc-documents` S3 bucket; only its mongo DB is dumped here.

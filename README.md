# db-backups

Automated backup solution for **PostgreSQL**, **MySQL/MariaDB**, and **MongoDB** instances running in Docker containers across multiple isolated docker-compose projects on the same host.

Each backup is compressed on-the-fly and uploaded to **AWS S3**. A lightweight HTTP endpoint exposes the result of the last run so external tools (n8n, UptimeRobot, etc.) can monitor backup health without SSH access.

---

## How it works

```
Host server
├── /opt/projects/
│   ├── project-alpha/   docker-compose.yml  (postgres + app)
│   ├── project-beta/    docker-compose.yml  (mysql + app)
│   └── project-gamma/   docker-compose.yml  (mysql + mongo + app)
│
└── /opt/db-backups/
    ├── backup.sh          ← runs on cron, no config per project needed
    ├── status-server.sh   ← tiny HTTP server, always running
    └── .env               ← only S3 credentials + global settings
```

### 1. Autodiscovery

`backup.sh` calls `docker ps` once and scans every running container. It matches containers by image name:

| Image pattern | Backup method |
|---|---|
| `postgres`, `postgres:*` | `pg_dump` |
| `mysql`, `mysql:*`, `mariadb`, `mariadb:*` | `mysqldump` |
| `mongo`, `mongo:*`, `mongodb:*` | `mongodump --archive --gzip` |

No list of projects or containers needs to be maintained. New projects are picked up automatically on the next run.

### 2. Credential extraction

Credentials are read from each container's own environment variables via `docker inspect`. No passwords are stored in the backup config.

| Engine | Variables read |
|---|---|
| PostgreSQL | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| MySQL | `MYSQL_USER` + `MYSQL_PASSWORD`, or `root` + `MYSQL_ROOT_PASSWORD` |
| MongoDB | `MONGO_INITDB_ROOT_USERNAME`, `MONGO_INITDB_ROOT_PASSWORD`, `MONGO_INITDB_DATABASE` |

A container that does not expose its password is **skipped with a warning** rather than failing the whole run.

### 3. Project grouping

Each container carries Docker Compose metadata as labels:

- `com.docker.compose.project` → project name (directory name by default)
- `com.docker.compose.service` → service name inside the compose file

These labels determine the S3 path and the key in the status JSON.
Containers started outside of compose use the container name as project/service.

### 4. S3 layout

```
{S3_PREFIX}/
  project-alpha/
    postgres/
      20260325_020001_db.sql.gz
  project-beta/
    mysql/
      20260325_020003_db.sql.gz
  project-gamma/
    mysql/
      20260325_020005_db.sql.gz
    mongodb/
      20260325_020007_db.archive.gz
```

### 5. Status JSON

After every run `backup.sh` writes a JSON file that `status-server.sh` serves over HTTP:

```json
{
  "overall": "success",
  "timestamp": "2026-03-25T02:01:30Z",
  "run_id": "20260325_020000",
  "databases": {
    "project-alpha::db": {
      "status": "ok",
      "size_bytes": 1048576,
      "s3_key": "db-backups/project-alpha/postgres/20260325_020001_db.sql.gz",
      "error": ""
    },
    "project-beta::db": {
      "status": "failed",
      "size_bytes": 0,
      "s3_key": "",
      "error": "mysqldump failed"
    }
  }
}
```

`overall` is `"success"` only when **all** discovered databases backed up and uploaded correctly. A single failure sets it to `"failed"`.

---

## Prerequisites

On the **host server**:

- Docker (with access to `docker ps` and `docker exec` as the backup user)
- AWS CLI v2 (`aws`)
- `python3` (status server — part of every modern Linux distro)
- `gzip`, `numfmt` (standard GNU coreutils)

```bash
# Verify
docker --version
aws --version
python3 --version
```

### IAM permissions required

The AWS credentials in `.env` need only these S3 actions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::your-bucket-name",
        "arn:aws:s3:::your-bucket-name/*"
      ]
    }
  ]
}
```

---

## Installation

### One-command install (recommended)

```bash
curl -sSL https://raw.githubusercontent.com/resitcl/script-backups/main/bootstrap.sh | sudo bash
```

The installer will prompt for S3 credentials and cron schedule, then configure cron and systemd automatically.

**To pre-set the cron schedule** (skips that prompt):

```bash
curl -sSL https://raw.githubusercontent.com/resitcl/script-backups/main/bootstrap.sh | sudo bash -s -- "0 3 * * *"
```

### Update

Re-run the same curl command. Your `.env` and cron schedule are preserved — only the scripts are updated.

```bash
curl -sSL https://raw.githubusercontent.com/resitcl/script-backups/main/bootstrap.sh | sudo bash
```

### Manual install (from a local clone)

```bash
git clone https://github.com/resitcl/script-backups.git /tmp/db-backups-src
cd /tmp/db-backups-src
cp .env.example .env
nano .env   # fill in S3 credentials
sudo bash install.sh "0 5 * * *"
```

---

## Configuration (`.env`)

| Variable | Required | Default | Description |
|---|---|---|---|
| `S3_BUCKET` | yes | — | S3 bucket name |
| `S3_PREFIX` | no | `db-backups` | Root folder inside the bucket |
| `AWS_ACCESS_KEY_ID` | yes | — | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | yes | — | IAM secret key |
| `AWS_DEFAULT_REGION` | no | `us-east-1` | AWS region |
| `BACKUP_TMP_DIR` | no | `/tmp/db-backups` | Local staging directory |
| `S3_RETENTION_DAYS` | no | `30` | Delete S3 objects older than N days. `0` disables |
| `STATUS_FILE` | no | `/var/www/backup-status/status.json` | Path of the status JSON |

There is **no per-project or per-container config**. All DB credentials are read at runtime from each container's environment.

---

## Status server

`status-server.sh` is a minimal Python 3 HTTP server that serves the status JSON.

```
GET http://<server>:8099/status
```

| HTTP code | Meaning |
|---|---|
| `200` | Last backup run succeeded (`overall: success`) |
| `503` | Last run failed, or no backup has run yet |
| `500` | Status file is unreadable / corrupt |

### Start / stop manually

```bash
# Managed by systemd after install
sudo systemctl status  backup-status-server
sudo systemctl restart backup-status-server
sudo systemctl stop    backup-status-server

# Run manually on a different port
./status-server.sh 9000
```

### Firewall

Open port 8099 only to trusted sources (n8n server IP, monitoring tool, VPN):

```bash
# ufw example
sudo ufw allow from <n8n-ip> to any port 8099
```

---

## Monitoring with n8n

Use an **HTTP Request** node on a schedule to poll the status endpoint.

### Recommended workflow

```
Schedule Trigger (every 6h)
  └─► HTTP Request
        Method: GET
        URL: http://<server>:8099/status
        Response: JSON
  └─► IF node
        overall == "success"   → (do nothing / update dashboard)
        overall != "success"   → Send alert (Slack / email / SMS)
```

The HTTP node response body matches the status JSON schema shown above. You can drill into individual databases via `{{ $json.databases }}` to report which specific project failed.

---

## Logs

```
/var/log/db-backup.log          ← all cron runs (appended)
/tmp/db-backups/backup_*.log    ← per-run log (kept until next run)
```

View the last run:

```bash
tail -50 /var/log/db-backup.log
```

---

## File reference

| File | Purpose |
|---|---|
| `backup.sh` | Main backup script — autodiscovers containers, dumps, compresses, uploads |
| `status-server.sh` | HTTP server exposing the status JSON on port 8099 |
| `status-server.service` | systemd unit for `status-server.sh` |
| `install.sh` | One-shot installer: cron + systemd setup |
| `.env.example` | Configuration template — copy to `.env` and fill in |

---

## Restore examples

### PostgreSQL

```bash
# Download from S3
aws s3 cp s3://my-bucket/db-backups/project-alpha/postgres/20260325_020001_db.sql.gz .

# Restore
gunzip -c 20260325_020001_db.sql.gz | docker exec -i <container> psql -U postgres mydb
```

### MySQL

```bash
aws s3 cp s3://my-bucket/db-backups/project-beta/mysql/20260325_020003_db.sql.gz .

gunzip -c 20260325_020003_db.sql.gz | docker exec -i <container> mysql -u root -p mydb
```

### MongoDB

```bash
aws s3 cp s3://my-bucket/db-backups/project-gamma/mongodb/20260325_020007_db.archive.gz .

# mongorestore reads the gzip archive format natively
docker exec -i <container> mongorestore \
  --username root --password secret \
  --authenticationDatabase admin \
  --gzip --archive \
  < 20260325_020007_db.archive.gz
```

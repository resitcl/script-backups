# mssql — SQL Server backups to S3 (Windows)

Windows counterpart of the root `backup.sh` for hosts that run **Microsoft SQL
Server directly** (no Docker). Same idea, same bucket, same S3 layout, same
status JSON — different tooling:

| | Linux fleet (`../backup.sh`) | This folder |
|---|---|---|
| Dump | `pg_dump` / `mysqldump` / `mongodump` via `docker exec` | native `BACKUP DATABASE ... WITH COMPRESSION, CHECKSUM` |
| Verify | — | `RESTORE VERIFYONLY WITH CHECKSUM` |
| Upload | `aws s3 cp --storage-class STANDARD_IA` | `aws s3 cp --storage-class STANDARD` (see [why](#why-standard-not-standard_ia)) |
| Retention | `apply_s3_retention` (list + delete) | same logic, `Apply-S3Retention` |
| Schedule | cron (`/etc/cron.d/db-backups`) | Task Scheduler (`db-backup-mssql`, runs as SYSTEM) |
| Config | `/opt/db-backups/.env` | `C:\db-backups\.env` |
| Status | `/var/www/backup-status/status.json` | `C:\db-backups\status.json` |

S3 key: `{S3_PREFIX}/{PROJECT_NAME}/mssql/{TIMESTAMP}_{db}.bak`

Nothing in the root of the repo is used or modified by these scripts.

## Files

- `backup-mssql.ps1` — the backup itself. Reads `.env`, backs up every DB in `DATABASES`, verifies, uploads, cleans local staging, applies S3 retention, writes `status.json`. Exit code 0 only when every DB succeeded.
- `install.ps1` — copies the files to `C:\db-backups`, fixes folder ACLs and SQL grants, registers the scheduled task. Safe to re-run.
- `.env.example` — config template. Copy to `.env`. Never commit `.env`.
- `precheck.sql` — diagnostic query to run in SSMS before installing (edition, recovery model, sizes, service accounts, existing backups, free disk).

## Requirements on the server

- SQL Server 2012 or newer. `BACKUP_COMPRESSION=1` needs Standard edition or higher (Express has no backup compression).
- `sqlcmd.exe` — ships with SQL Server and with SSMS.
- PowerShell 3.0 or newer (Windows Server 2012 ships 3.0; the script avoids newer cmdlets on purpose).
- **AWS CLI v2** (`aws --version`). Not installed by `install.ps1`. See [AWS CLI on old Windows](#aws-cli-on-old-windows).

## Install (first time)

1. Run `precheck.sql` in SSMS (results to text) and keep the output: recovery model, DB size, service account, free disk.
2. Copy this folder to the server (RDP clipboard / drive redirection, or download the repo zip from GitHub). Git is usually not present on these hosts.
3. Install the AWS CLI v2 if `aws --version` fails.
4. From an elevated PowerShell, logged in as a Windows account that is `sysadmin` on the instance:
   ```powershell
   cd <folder>\mssql
   powershell -ExecutionPolicy Bypass -File install.ps1            # daily 02:00
   ```
   What it does:
   - installs to `C:\db-backups`, creates `staging\` and `logs\`;
   - grants the **SQL Server service account** (`NT Service\MSSQLSERVER`) Modify on the staging folder — `BACKUP DATABASE` writes the file as that account, not as whoever runs the script. This is the classic "Operating system error 5 (Access is denied)" trap;
   - creates a login for `NT AUTHORITY\SYSTEM` (the account the task runs as) with `db_backupoperator` on each DB and `dbcreator` (needed by `RESTORE VERIFYONLY`). No `sysadmin`;
   - registers the scheduled task `db-backup-mssql`.
5. Fill `C:\db-backups\.env`: S3 credentials copied from any Linux server's `/opt/db-backups/.env` (shared across the fleet), a **per-server `S3_PREFIX`**, `DATABASES`, `PROJECT_NAME`.
6. Validate:
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\db-backups\backup-mssql.ps1
   type C:\db-backups\status.json
   aws s3 ls s3://resit-prod-2026/<S3_PREFIX>/<PROJECT_NAME>/mssql/
   schtasks /Run /TN db-backup-mssql        # run once as SYSTEM, exactly like the schedule will
   schtasks /Query /TN db-backup-mssql /V /FO LIST | findstr /i "result last"
   ```
   The second run is the important one: it proves the SYSTEM account has the SQL and folder rights.
7. **Restore test** — a backup nobody has restored is not a backup:
   ```sql
   RESTORE DATABASE [alcsaDESA_restoretest]
     FROM DISK = N'C:\db-backups\staging\<file>.bak'
     WITH MOVE 'alcsaDESA' TO N'C:\db-backups\restoretest.mdf',
          MOVE 'alcsaDESA_log' TO N'C:\db-backups\restoretest.ldf',
          CHECKSUM, STATS = 10;
   DROP DATABASE [alcsaDESA_restoretest];
   ```
   (Logical file names: `SELECT name FROM sys.master_files WHERE database_id = DB_ID('alcsaDESA')`.)

## Update an installed server

Copy the new `backup-mssql.ps1` over `C:\db-backups\backup-mssql.ps1`, or re-run `install.ps1` (it never touches an existing `.env`).

## Monitoring

`status.json` has the same shape as the Linux one, so any consumer of the fleet's status works unchanged:

```json
{
  "overall": "success",
  "timestamp": "2026-09-10T05:03:12Z",
  "run_id": "20260910_050001",
  "databases": {
    "alcsa::alcsaDESA": { "status": "ok", "size_bytes": 1234567890, "s3_key": "db-backups-alcsa/alcsa/mssql/20260910_050001_alcsaDESA.bak", "error": "" }
  }
}
```

There is no HTTP status server for Windows yet. Until there is, check the scheduled task's last result (`schtasks /Query`), the log in `C:\db-backups\logs\`, or the S3 listing.

## Notes and gotchas

### Recovery model

The script takes **full backups only**. That is correct for a database in `SIMPLE` recovery. If the DB is in `FULL` recovery and nothing takes log backups, the log file grows without limit — either switch it to `SIMPLE` (`ALTER DATABASE [x] SET RECOVERY SIMPLE`) when a daily RPO is acceptable, or add log backups. `precheck.sql` prints the model.

### Why STANDARD, not STANDARD_IA

The Linux script uploads to `STANDARD_IA`. That class bills a **30-day minimum** per object plus a retrieval fee. With a 15-day retention every object is billed for twice its lifetime, so `STANDARD` is cheaper. Change `--storage-class` in `Upload-ToS3` if the retention ever grows past ~45 days.

### Retention

Script-side, like the Linux fleet: after each run it lists `{S3_PREFIX}/` and deletes objects older than `S3_RETENTION_DAYS`. Everything under the prefix is subject to it, so keep one prefix per server. If you want retention to keep working even when the server is down, add an S3 lifecycle rule on the same prefix with the same number of days — harmless duplication.

### Existing SQL Agent jobs

The script does not touch existing Agent jobs or maintenance plans. If the host already has a job writing a `.bak` somewhere, both will run; that is fine (they are independent) but it doubles disk churn. Retire the old one once this is validated, or leave it as a local extra copy.

### AWS CLI on old Windows

Windows Server 2012 (not R2) is out of Microsoft support and recent AWS CLI v2 installers may refuse to install or fail to start on it. If the current MSI (`https://awscli.amazonaws.com/AWSCLIV2.msi`) does not work, install a pinned older 2.x build — versioned MSIs exist, e.g. `https://awscli.amazonaws.com/AWSCLIV2-2.13.33.msi`. After installing, open a **new** PowerShell so `PATH` is refreshed, or rely on the script's fallback to `C:\Program Files\Amazon\AWSCLIV2\aws.exe`.

### Deployed servers

- **alcsa server** (`WIN-KNKMLV2CO2O`, Windows Server 2012 x64, SQL Server 2012 Standard RTM 11.0.2100, default instance, SSMS present, Windows App connection "alcsa server" as `Administrador`).
  - S3: bucket `resit-prod-2026`, prefix `db-backups-alcsa`, project `alcsa`.
  - Databases: `alcsaDESA` only (SIMPLE recovery, ~8 GB data file, no FileTables/FILESTREAM, uncompressed full backup ≈ 5.2 GB so expect ~1–1.5 GB compressed). The other DBs on the instance (`agrodashboard`, `ALCSA_DOCUMENTOS*`, `ALCSA_Log`, `Demo_Alcsa`, `Testing_Alcsa`) are intentionally **not** backed up here.
  - Pre-existing: Agent job `Genera Respaldo BD` writes an uncompressed `alcsaDESA.Bak` to the instance's default backup folder at 21:00 on weekdays (no weekend runs, no S3). Left untouched.
  - Services run as `NT Service\MSSQLSERVER` / `NT Service\SQLSERVERAGENT`; `NT AUTHORITY\SYSTEM` had no SQL login before `install.ps1`. `xp_cmdshell` disabled. Disk `C:` had ~324 GB free of 953 GB.
  - Schedule: daily 02:00 (server local time), retention 15 days.
  - Installed 2026-09-09: AWS CLI **2.13.33** pinned (`AWSCLIV2-2.13.33.msi`, reports `Windows/2012Server`); files copied via a send.resit.cl share and extracted with `[IO.Compression.ZipFile]` (no git, no Expand-Archive on PS 3.0). Manual run and a `schtasks /Run` as SYSTEM both ended `overall: success`; compressed .bak ≈ 900 MB, upload ≈ 3.5 min. Restore test still pending.

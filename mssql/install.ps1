# install.ps1 — installs backup-mssql.ps1 on a Windows host running SQL Server.
#
#   1. Copies the script and .env.example to C:\db-backups (never overwrites an
#      existing .env).
#   2. Creates the staging/log folders and gives the SQL Server service account
#      write access (BACKUP DATABASE writes the file as that account, not as the
#      user running the script).
#   3. Grants the account the scheduled task runs as (NT AUTHORITY\SYSTEM) the
#      minimum SQL rights: db_backupoperator on each database in DATABASES plus
#      the dbcreator server role (needed by RESTORE VERIFYONLY).
#   4. Registers a daily scheduled task.
#
# Run from an elevated PowerShell, as a Windows login that is sysadmin on the
# instance (e.g. the local Administrator):
#
#   powershell -ExecutionPolicy Bypass -File install.ps1              # 02:00 daily
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Time 03:30  # other time
#
# Re-running is safe.

param(
    [string]$InstallDir = 'C:\db-backups',
    [string]$Time       = '02:00',
    [string]$TaskName   = 'db-backup-mssql',
    [string]$SqlInstance = '.',
    [switch]$SkipSqlGrants
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'Run this from an elevated (Administrator) PowerShell.'; exit 1 }

# ─── 1. Files ────────────────────────────────────────────────────────────────
foreach ($d in @($InstallDir, "$InstallDir\staging", "$InstallDir\logs")) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
Copy-Item (Join-Path $ScriptDir 'backup-mssql.ps1') $InstallDir -Force
Copy-Item (Join-Path $ScriptDir '.env.example')     $InstallDir -Force
if (-not (Test-Path "$InstallDir\.env")) {
    Copy-Item "$InstallDir\.env.example" "$InstallDir\.env"
    Write-Host "Created $InstallDir\.env from the example - fill in the S3 credentials before the first run."
}
Write-Host "Files installed to $InstallDir"

# Read DATABASES / BACKUP_DIR from the installed .env so the grants match it
$cfg = @{}
foreach ($line in Get-Content "$InstallDir\.env") {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith('#') -or $l.IndexOf('=') -lt 1) { continue }
    $cfg[$l.Substring(0, $l.IndexOf('=')).Trim()] = ($l.Substring($l.IndexOf('=') + 1) -replace '\s+#.*$', '').Trim()
}
$databases = @(($cfg['DATABASES'] -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$backupDir = if ($cfg['BACKUP_DIR']) { $cfg['BACKUP_DIR'] } else { "$InstallDir\staging" }
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

# ─── 2. Folder ACL for the SQL Server service account ────────────────────────
$svcName = if ($SqlInstance -match '\\(.+)$') { 'MSSQL$' + $Matches[1] } else { 'MSSQLSERVER' }
$svc = Get-WmiObject Win32_Service -Filter "Name='$svcName'"
if ($svc) {
    $account = $svc.StartName
    if ($account -eq 'LocalSystem') { $account = 'NT AUTHORITY\SYSTEM' }
    & icacls $backupDir /grant "${account}:(OI)(CI)M" /T | Out-Null
    Write-Host "Granted Modify on $backupDir to $account (SQL Server service account)"
} else {
    Write-Host "WARNING: service $svcName not found - grant the SQL Server service account write access to $backupDir by hand."
}

# ─── 3. SQL rights for the task account ──────────────────────────────────────
if (-not $SkipSqlGrants) {
    $taskLogin = 'NT AUTHORITY\SYSTEM'
    $sql = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$taskLogin')
    CREATE LOGIN [$taskLogin] FROM WINDOWS;
IF IS_SRVROLEMEMBER('dbcreator', N'$taskLogin') = 0
    ALTER SERVER ROLE [dbcreator] ADD MEMBER [$taskLogin];
"@
    foreach ($db in $databases) {
        $sql += @"

USE [$db];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$taskLogin')
    CREATE USER [$taskLogin] FOR LOGIN [$taskLogin];
ALTER ROLE [db_backupoperator] ADD MEMBER [$taskLogin];
"@
    }
    $tmp = Join-Path $env:TEMP 'db-backup-grants.sql'
    Set-Content -Path $tmp -Value $sql
    & sqlcmd -S $SqlInstance -E -b -i $tmp
    if ($LASTEXITCODE -ne 0) { Write-Host 'SQL grants failed (see above). Fix and re-run, or use SQL_USER/SQL_PASSWORD in .env.'; exit 1 }
    Remove-Item $tmp -Force
    Write-Host "Granted db_backupoperator on [$($databases -join '], [')] + dbcreator to $taskLogin"
}

# ─── 4. Scheduled task ───────────────────────────────────────────────────────
$action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstallDir\backup-mssql.ps1"
& schtasks /Create /F /TN $TaskName /SC DAILY /ST $Time /RU SYSTEM /RL HIGHEST /TR $action | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'schtasks failed'; exit 1 }
Write-Host "Scheduled task '$TaskName' registered: daily at $Time as SYSTEM"

Write-Host ''
Write-Host 'Next steps:'
Write-Host "  1. notepad $InstallDir\.env   (S3 credentials, S3_PREFIX, DATABASES)"
Write-Host "  2. aws --version               (install the AWS CLI v2 if missing)"
Write-Host "  3. powershell -ExecutionPolicy Bypass -File $InstallDir\backup-mssql.ps1   (manual run)"
Write-Host "  4. schtasks /Run /TN $TaskName  then check $InstallDir\status.json and $InstallDir\logs"

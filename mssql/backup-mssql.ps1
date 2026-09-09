# backup-mssql.ps1 — backs up one or more SQL Server databases with native
#                    BACKUP DATABASE (compressed + checksum), verifies each
#                    .bak, uploads it to S3, applies S3 retention and writes a
#                    status JSON with the same shape as the Linux backup.sh.
#
# Windows counterpart of ../backup.sh for hosts that run SQL Server directly
# (no Docker). Config comes from a .env file next to this script — copy
# .env.example and fill it in.
#
# S3 layout:
#   {S3_PREFIX}/{PROJECT_NAME}/mssql/{TIMESTAMP}_{db}.bak
#
# Requirements: sqlcmd.exe (ships with SQL Server / SSMS), AWS CLI v2,
#               PowerShell 3.0 or newer (Windows Server 2012 ships 3.0).
#
# Usage:  powershell -ExecutionPolicy Bypass -File backup-mssql.ps1

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ─── Load config ─────────────────────────────────────────────────────────────
$EnvFile = Join-Path $ScriptDir '.env'
if (-not (Test-Path $EnvFile)) {
    Write-Host "Missing .env - copy .env.example and fill it in."
    exit 1
}
$Cfg = @{}
foreach ($line in Get-Content $EnvFile) {
    $l = $line.Trim()
    if ($l -eq '' -or $l.StartsWith('#')) { continue }
    $idx = $l.IndexOf('=')
    if ($idx -lt 1) { continue }
    $k = $l.Substring(0, $idx).Trim()
    $v = $l.Substring($idx + 1)
    # strip trailing inline comment and surrounding quotes
    $v = ($v -replace '\s+#.*$', '').Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
        $v = $v.Substring(1, $v.Length - 2)
    }
    $Cfg[$k] = $v
}
function Cfg($name, $default) {
    if ($Cfg.ContainsKey($name) -and $Cfg[$name] -ne '') { return $Cfg[$name] }
    return $default
}

# ─── Defaults ────────────────────────────────────────────────────────────────
$S3Bucket        = Cfg 'S3_BUCKET' ''
$S3Prefix        = (Cfg 'S3_PREFIX' 'db-backups').TrimEnd('/')
$SqlInstance     = Cfg 'SQL_INSTANCE' '.'
$Databases       = @((Cfg 'DATABASES' '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$ProjectName     = Cfg 'PROJECT_NAME' ($env:COMPUTERNAME.ToLower())
$SqlUser         = Cfg 'SQL_USER' ''
$SqlPassword     = Cfg 'SQL_PASSWORD' ''
$UseCompression  = (Cfg 'BACKUP_COMPRESSION' '1') -eq '1'
$Verify          = (Cfg 'VERIFY' '1') -eq '1'
$BackupDir       = Cfg 'BACKUP_DIR' 'C:\db-backups\staging'
$LocalKeepDays   = [int](Cfg 'LOCAL_KEEP_DAYS' '1')
$RetentionDays   = [int](Cfg 'S3_RETENTION_DAYS' '15')
$LogDir          = Cfg 'LOG_DIR' 'C:\db-backups\logs'
$StatusFile      = Cfg 'STATUS_FILE' 'C:\db-backups\status.json'

$Timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
foreach ($d in @($BackupDir, $LogDir, (Split-Path -Parent $StatusFile))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$LogFile = Join-Path $LogDir "backup_$Timestamp.log"

# AWS CLI reads credentials from the process environment
$env:AWS_ACCESS_KEY_ID     = Cfg 'AWS_ACCESS_KEY_ID' ''
$env:AWS_SECRET_ACCESS_KEY = Cfg 'AWS_SECRET_ACCESS_KEY' ''
$env:AWS_DEFAULT_REGION    = Cfg 'AWS_DEFAULT_REGION' 'us-east-1'

# ─── Logging ─────────────────────────────────────────────────────────────────
function Log($msg) {
    $line = "[{0}] {1}" -f (Get-Date).ToUniversalTime().ToString('HH:mm:ss'), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}
function Fail($msg) { Log "ERROR: $msg" }

# ─── Tool discovery ──────────────────────────────────────────────────────────
function Find-Exe($name, $fallbacks) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Path }
    foreach ($f in $fallbacks) { if ($f -and (Test-Path $f)) { return $f } }
    return $null
}
$SqlCmd = Find-Exe 'sqlcmd.exe' @(
    (Get-ChildItem 'C:\Program Files\Microsoft SQL Server\*\Tools\Binn\SQLCMD.EXE' -ErrorAction SilentlyContinue | Select-Object -Last 1 -ExpandProperty FullName),
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\SQLCMD.EXE',
    'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\SQLCMD.EXE'
)
$AwsCli = Find-Exe 'aws.exe' @('C:\Program Files\Amazon\AWSCLIV2\aws.exe')

# ─── Per-database result tracking (same shape as backup.sh) ──────────────────
# Keys use format "project::db"
$Results = @{}
$script:Overall = 'success'

function Record-Ok($key, $size, $s3key) {
    $Results[$key] = @{ status = 'ok'; size_bytes = $size; s3_key = $s3key; error = '' }
}
function Record-Fail($key, $reason) {
    $Results[$key] = @{ status = 'failed'; size_bytes = 0; s3_key = ''; error = $reason }
    $script:Overall = 'failed'
}

# ─── SQL helper ──────────────────────────────────────────────────────────────
# Runs a T-SQL batch through sqlcmd. -b makes sqlcmd exit non-zero on any SQL
# error so we can rely on $LASTEXITCODE. Returns the combined output.
function Invoke-Sql($query) {
    $ErrorActionPreference = 'Continue'   # stderr from native exes must not become a terminating error
    $a = @('-S', $SqlInstance, '-b', '-Q', $query)
    if ($SqlUser -ne '') { $a += @('-U', $SqlUser, '-P', $SqlPassword) } else { $a += '-E' }
    $out = & $SqlCmd @a 2>&1
    return ,@($LASTEXITCODE, ($out | Out-String).Trim())
}

# ─── S3 upload ───────────────────────────────────────────────────────────────
# STANDARD (not STANDARD_IA) on purpose: IA bills a 30-day minimum per object,
# so with a 15-day retention it would cost more than STANDARD.
function Upload-ToS3($localFile, $s3key) {
    $ErrorActionPreference = 'Continue'
    $out = & $AwsCli s3 cp $localFile "s3://$S3Bucket/$s3key" --storage-class STANDARD --only-show-errors 2>&1
    return ,@($LASTEXITCODE, ($out | Out-String).Trim())
}

# ─── Backup one database ─────────────────────────────────────────────────────
function Backup-Database($db) {
    $key     = "${ProjectName}::$db"
    $file    = "${Timestamp}_$db.bak"
    $local   = Join-Path $BackupDir $file
    $s3key   = "$S3Prefix/$ProjectName/mssql/$file"
    $safeDb  = $db.Replace(']', ']]')
    $safePath = $local.Replace("'", "''")

    Log "[$db] Backing up to $local"
    $opts = 'INIT, CHECKSUM, STATS = 10'
    if ($UseCompression) { $opts = "COMPRESSION, $opts" }
    $r = Invoke-Sql "BACKUP DATABASE [$safeDb] TO DISK = N'$safePath' WITH $opts"
    if ($r[0] -ne 0) {
        Fail "[$db] BACKUP DATABASE failed: $($r[1])"
        Record-Fail $key "backup failed: $($r[1])"
        Remove-Item $local -ErrorAction SilentlyContinue
        return
    }
    if (-not (Test-Path $local)) {
        Fail "[$db] BACKUP reported success but $local does not exist (check the SQL Server service account has write access to $BackupDir)"
        Record-Fail $key "backup file missing after BACKUP DATABASE"
        return
    }
    $size = (Get-Item $local).Length
    Log ("[$db] Backup done ({0:N1} MB)" -f ($size / 1MB))

    if ($Verify) {
        Log "[$db] Verifying"
        $r = Invoke-Sql "RESTORE VERIFYONLY FROM DISK = N'$safePath' WITH CHECKSUM"
        if ($r[0] -ne 0) {
            Fail "[$db] RESTORE VERIFYONLY failed: $($r[1])"
            Record-Fail $key "verify failed: $($r[1])"
            return
        }
    }

    Log "[$db] Uploading to s3://$S3Bucket/$s3key"
    $r = Upload-ToS3 $local $s3key
    if ($r[0] -ne 0) {
        Fail "[$db] Upload failed: $($r[1])"
        Record-Fail $key "upload failed: $($r[1])"
        return
    }
    Log "[$db] Upload OK"
    Record-Ok $key $size $s3key
}

# ─── Local cleanup ───────────────────────────────────────────────────────────
function Clean-Local {
    $cutoff = (Get-Date).AddDays(-$LocalKeepDays)
    $failedNow = @($Results.Values | Where-Object { $_.status -eq 'failed' }).Count -gt 0
    Get-ChildItem -Path $BackupDir -Filter '*.bak' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            # never delete a file from a run that failed to upload
            if ($failedNow -and $_.Name.StartsWith($Timestamp)) { return }
            Log "[local] Deleting $($_.FullName)"
            Remove-Item $_.FullName -Force
        }
    Get-ChildItem -Path $LogDir -Filter 'backup_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ─── S3 retention ────────────────────────────────────────────────────────────
function Apply-S3Retention {
    if ($RetentionDays -le 0) { return }
    $ErrorActionPreference = 'Continue'
    Log "[retention] Removing objects older than $RetentionDays days under $S3Prefix/"
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$RetentionDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
    $out = & $AwsCli s3api list-objects-v2 --bucket $S3Bucket --prefix "$S3Prefix/" `
        --query "Contents[?LastModified<='$cutoff'].Key" --output text 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "[retention] list-objects failed: $out"; return }
    $keys = ($out | Out-String) -split '\s+' | Where-Object { $_ -ne '' -and $_ -ne 'None' }
    foreach ($k in $keys) {
        Log "[retention] Deleting s3://$S3Bucket/$k"
        & $AwsCli s3 rm "s3://$S3Bucket/$k" --only-show-errors 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "[retention] could not delete $k" }
    }
}

# ─── Status JSON ─────────────────────────────────────────────────────────────
function Write-Status {
    if ($Results.Count -eq 0) {
        $script:Overall = 'failed'
        $Results['_discovery'] = @{ status = 'failed'; size_bytes = 0; s3_key = ''; error = 'No databases configured' }
    }
    $status = @{
        overall   = $script:Overall
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        run_id    = $Timestamp
        databases = $Results
    }
    $json = $status | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($StatusFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Log "Status written -> $StatusFile"
}

# ─── Main ────────────────────────────────────────────────────────────────────
Log "======== Backup run $Timestamp ========"

$fatal = $null
if (-not $SqlCmd)  { $fatal = 'sqlcmd.exe not found' }
elseif (-not $AwsCli) { $fatal = 'aws.exe not found - install the AWS CLI v2' }
elseif ($S3Bucket -eq '') { $fatal = 'S3_BUCKET is empty' }
elseif ($Databases.Count -eq 0) { $fatal = 'DATABASES is empty' }

if ($fatal) {
    Fail $fatal
    foreach ($db in $Databases) { Record-Fail "${ProjectName}::$db" $fatal }
    Write-Status
    exit 1
}

foreach ($db in $Databases) {
    try { Backup-Database $db }
    catch { Fail "[$db] $($_.Exception.Message)"; Record-Fail "${ProjectName}::$db" $_.Exception.Message }
}

try { Clean-Local } catch { Fail "[local] $($_.Exception.Message)" }
try { Apply-S3Retention } catch { Fail "[retention] $($_.Exception.Message)" }

Write-Status
Log "======== Done. Overall: $script:Overall ========"
if ($script:Overall -eq 'success') { exit 0 } else { exit 1 }

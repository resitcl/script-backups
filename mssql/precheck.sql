-- precheck.sql — run in SSMS (results to text, Ctrl+T) before installing.
-- Prints edition, recovery model, sizes, paths, service accounts, existing
-- backups and free disk so the .env can be filled in without guessing.
-- The temp table avoids collation conflicts between server and DB defaults.
-- Replace alcsaDESA with the target database name.
SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r(k varchar(40) COLLATE DATABASE_DEFAULT, v varchar(500) COLLATE DATABASE_DEFAULT);
INSERT #r SELECT 'edition', CAST(SERVERPROPERTY('Edition') AS varchar(200));
INSERT #r SELECT 'version', CAST(SERVERPROPERTY('ProductVersion') AS varchar(200));
INSERT #r SELECT 'level', CAST(SERVERPROPERTY('ProductLevel') AS varchar(200));
INSERT #r SELECT 'instance', CAST(ISNULL(SERVERPROPERTY('InstanceName'),'MSSQLSERVER') AS varchar(200));
INSERT #r SELECT 'machine', CAST(SERVERPROPERTY('MachineName') AS varchar(200));
INSERT #r SELECT 'os', REPLACE(REPLACE(CAST(@@VERSION AS varchar(400)),CHAR(13),' '),CHAR(10),' ');
INSERT #r SELECT 'recovery', recovery_model_desc FROM sys.databases WHERE name='alcsaDESA';
INSERT #r SELECT 'compat', CAST(compatibility_level AS varchar(10)) FROM sys.databases WHERE name='alcsaDESA';
INSERT #r SELECT 'file_'+type_desc+'_mb', CAST(SUM(size)/128 AS varchar(20)) FROM sys.master_files WHERE database_id=DB_ID('alcsaDESA') GROUP BY type_desc;
INSERT #r SELECT 'file_path', physical_name FROM sys.master_files WHERE database_id=DB_ID('alcsaDESA');
INSERT #r SELECT 'filetables', CAST(COUNT(*) AS varchar(10)) FROM alcsaDESA.sys.tables WHERE is_filetable=1;
INSERT #r SELECT 'filestream_level', CAST(SERVERPROPERTY('FilestreamConfiguredLevel') AS varchar(10));
INSERT #r SELECT 'compression_default', CAST(value_in_use AS varchar(10)) FROM sys.configurations WHERE name='backup compression default';
INSERT #r SELECT 'svc_'+servicename, service_account+' | '+status_desc FROM sys.dm_server_services;
INSERT #r SELECT 'last_full_backup', ISNULL(CAST(MAX(backup_finish_date) AS varchar(30)),'never') FROM msdb.dbo.backupset WHERE database_name='alcsaDESA' AND type='D';
INSERT #r SELECT 'last_log_backup', ISNULL(CAST(MAX(backup_finish_date) AS varchar(30)),'never') FROM msdb.dbo.backupset WHERE database_name='alcsaDESA' AND type='L';
INSERT #r SELECT 'last_backup_dest', physical_device_name FROM msdb.dbo.backupmediafamily WHERE media_set_id=(SELECT TOP 1 media_set_id FROM msdb.dbo.backupset WHERE database_name='alcsaDESA' ORDER BY backup_finish_date DESC);
INSERT #r SELECT 'default_data_path', CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS varchar(300));
INSERT #r SELECT 'default_backup_dir', CAST(value_data AS varchar(300)) FROM sys.dm_server_registry WHERE value_name='BackupDirectory';
INSERT #r SELECT DISTINCT 'drive_'+volume_mount_point, 'free_mb='+CAST(available_bytes/1048576 AS varchar(20))+' total_mb='+CAST(total_bytes/1048576 AS varchar(20)) FROM sys.master_files mf CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id);
INSERT #r SELECT 'xp_cmdshell', CAST(value_in_use AS varchar(10)) FROM sys.configurations WHERE name='xp_cmdshell';
INSERT #r SELECT 'sysadmin_logins', STUFF((SELECT ', '+name FROM sys.server_principals WHERE IS_SRVROLEMEMBER('sysadmin',name)=1 AND name NOT LIKE '##%' FOR XML PATH('')),1,2,'');
SELECT RTRIM(k) + ' = ' + ISNULL(v, 'NULL') AS kv FROM #r;

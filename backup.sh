#!/usr/bin/env bash
# backup.sh — autodiscovers ALL running PostgreSQL, MySQL/MariaDB and MongoDB
#             containers across every docker-compose project on this host,
#             dumps + compresses each one, uploads to S3, and writes a status
#             JSON for external monitoring.
#
# Credentials are read directly from each container's own environment variables
# (POSTGRES_PASSWORD, MYSQL_ROOT_PASSWORD, MONGO_INITDB_ROOT_PASSWORD, etc.)
# so no per-project config is needed.
#
# S3 layout:
#   {S3_PREFIX}/{project}/{db_type}/{TIMESTAMP}_{service}.{ext}
#
# Usage:  ./backup.sh
set -euo pipefail

# ─── Load config ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE" || { echo "Missing .env — copy .env.example and fill it in."; exit 1; }

# ─── Defaults ────────────────────────────────────────────────────────────────
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/tmp/db-backups}"
S3_RETENTION_DAYS="${S3_RETENTION_DAYS:-30}"
STATUS_FILE="${STATUS_FILE:-/var/www/backup-status/status.json}"
TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG_FILE="${BACKUP_TMP_DIR}/backup_${TIMESTAMP}.log"

mkdir -p "$BACKUP_TMP_DIR"
mkdir -p "$(dirname "$STATUS_FILE")"

# ─── Logging ─────────────────────────────────────────────────────────────────
log()  { echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; }

# ─── Per-container result tracking ───────────────────────────────────────────
# Keys use format  "project::service"  (double-colon avoids clashing with paths)
declare -A RESULT_STATUS=()   # → ok | failed | skipped
declare -A RESULT_ERROR=()    # → error message or ""
declare -A RESULT_SIZE=()     # → compressed bytes
declare -A RESULT_S3KEY=()    # → s3 key on success
OVERALL="success"

record_ok() {
  local key="$1" size="$2" s3key="$3"
  RESULT_STATUS["$key"]="ok"
  RESULT_ERROR["$key"]=""
  RESULT_SIZE["$key"]="$size"
  RESULT_S3KEY["$key"]="$s3key"
}

record_fail() {
  local key="$1" reason="$2"
  RESULT_STATUS["$key"]="failed"
  RESULT_ERROR["$key"]="$reason"
  RESULT_SIZE["$key"]="0"
  RESULT_S3KEY["$key"]=""
  OVERALL="failed"
}

# ─── Docker helpers ───────────────────────────────────────────────────────────

# Read one environment variable from a running container
container_env() {
  local container="$1" var="$2"
  docker inspect \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    "$container" 2>/dev/null \
    | grep "^${var}=" | head -1 | cut -d= -f2-
}

# Read one Docker label from a running container
container_label() {
  local container="$1" label="$2"
  docker inspect \
    --format "{{index .Config.Labels \"${label}\"}}" \
    "$container" 2>/dev/null || true
}

# ─── S3 upload ────────────────────────────────────────────────────────────────
upload_to_s3() {
  local local_file="$1" s3_key="$2"
  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
  aws s3 cp "$local_file" "s3://${S3_BUCKET}/${s3_key}" \
    --storage-class STANDARD_IA \
    --only-show-errors
}

# ─── PostgreSQL backup ────────────────────────────────────────────────────────
backup_postgres() {
  local container="$1" project="$2" service="$3"
  local key="${project}::${service}"
  log "[postgres][${project}/${service}] Reading credentials from container env..."

  local pg_user pg_pass pg_db
  pg_user="$(container_env "$container" POSTGRES_USER)"
  pg_pass="$(container_env "$container" POSTGRES_PASSWORD)"
  pg_db="$(container_env "$container" POSTGRES_DB)"

  # Sensible fallbacks matching official postgres image defaults
  pg_user="${pg_user:-postgres}"
  pg_db="${pg_db:-${pg_user}}"

  if [[ -z "$pg_pass" ]]; then
    fail "[postgres][${project}/${service}] POSTGRES_PASSWORD not set in container — skipping"
    record_fail "$key" "POSTGRES_PASSWORD not found in container env"
    return
  fi

  local filename="${TIMESTAMP}_${service}.sql.gz"
  local local_path="${BACKUP_TMP_DIR}/${project}_${filename}"
  local s3_key="${S3_PREFIX}/${project}/postgres/${filename}"

  log "[postgres][${project}/${service}] Dumping database '${pg_db}'..."
  if docker exec -e PGPASSWORD="$pg_pass" "$container" \
      pg_dump -U "$pg_user" "$pg_db" \
    | gzip > "$local_path" 2>>"$LOG_FILE"; then
    local size
    size=$(stat -c%s "$local_path")
    log "[postgres][${project}/${service}] Dump OK ($(numfmt --to=iec "$size")). Uploading..."
    if upload_to_s3 "$local_path" "$s3_key"; then
      log "[postgres][${project}/${service}] Upload OK → s3://${S3_BUCKET}/${s3_key}"
      record_ok "$key" "$size" "$s3_key"
    else
      fail "[postgres][${project}/${service}] S3 upload failed"
      record_fail "$key" "S3 upload failed"
    fi
  else
    fail "[postgres][${project}/${service}] pg_dump failed — see log for details"
    record_fail "$key" "pg_dump failed"
  fi
  rm -f "$local_path"
}

# ─── MySQL / MariaDB backup ───────────────────────────────────────────────────
backup_mysql() {
  local container="$1" project="$2" service="$3"
  local key="${project}::${service}"
  log "[mysql][${project}/${service}] Reading credentials from container env..."

  local my_user my_pass my_db
  # Prefer explicit user; fall back to root. The mariadb image sets MARIADB_*
  # and ships no MYSQL_* aliases, so check both prefixes.
  my_user="$(container_env "$container" MYSQL_USER)"
  my_pass="$(container_env "$container" MYSQL_PASSWORD)"
  my_db="$(container_env "$container" MYSQL_DATABASE)"
  [[ -z "$my_user" ]] && my_user="$(container_env "$container" MARIADB_USER)"
  [[ -z "$my_pass" ]] && my_pass="$(container_env "$container" MARIADB_PASSWORD)"
  [[ -z "$my_db"   ]] && my_db="$(container_env "$container" MARIADB_DATABASE)"

  # If no regular user, try root
  if [[ -z "$my_pass" ]]; then
    my_user="root"
    my_pass="$(container_env "$container" MYSQL_ROOT_PASSWORD)"
    [[ -z "$my_pass" ]] && my_pass="$(container_env "$container" MARIADB_ROOT_PASSWORD)"
  fi
  my_user="${my_user:-root}"

  if [[ -z "$my_pass" ]]; then
    fail "[mysql][${project}/${service}] No password found (MYSQL_/MARIADB_ PASSWORD or ROOT_PASSWORD) — skipping"
    record_fail "$key" "No MySQL password found in container env"
    return
  fi

  # If no specific DB, dump all databases
  local dump_args
  if [[ -n "$my_db" ]]; then
    dump_args="$my_db"
  else
    dump_args="--all-databases"
  fi

  local filename="${TIMESTAMP}_${service}.sql.gz"
  local local_path="${BACKUP_TMP_DIR}/${project}_${filename}"
  local s3_key="${S3_PREFIX}/${project}/mysql/${filename}"

  # MariaDB 11 dropped the mysqldump symlink and ships mariadb-dump instead.
  local dump_bin="mysqldump"
  if ! docker exec "$container" sh -c 'command -v mysqldump' >/dev/null 2>&1; then
    dump_bin="mariadb-dump"
  fi

  log "[mysql][${project}/${service}] Dumping ${dump_args} with ${dump_bin}..."
  if docker exec "$container" \
      "$dump_bin" -u "$my_user" -p"$my_pass" \
        --single-transaction --quick \
        $dump_args \
    | gzip > "$local_path" 2>>"$LOG_FILE"; then
    local size
    size=$(stat -c%s "$local_path")
    log "[mysql][${project}/${service}] Dump OK ($(numfmt --to=iec "$size")). Uploading..."
    if upload_to_s3 "$local_path" "$s3_key"; then
      log "[mysql][${project}/${service}] Upload OK → s3://${S3_BUCKET}/${s3_key}"
      record_ok "$key" "$size" "$s3_key"
    else
      fail "[mysql][${project}/${service}] S3 upload failed"
      record_fail "$key" "S3 upload failed"
    fi
  else
    fail "[mysql][${project}/${service}] ${dump_bin} failed — see log for details"
    record_fail "$key" "${dump_bin} failed"
  fi
  rm -f "$local_path"
}

# ─── MongoDB backup ───────────────────────────────────────────────────────────
backup_mongo() {
  local container="$1" project="$2" service="$3"
  local key="${project}::${service}"
  log "[mongodb][${project}/${service}] Reading credentials from container env..."

  local mongo_user mongo_pass mongo_db
  mongo_user="$(container_env "$container" MONGO_INITDB_ROOT_USERNAME)"
  mongo_pass="$(container_env "$container" MONGO_INITDB_ROOT_PASSWORD)"
  mongo_db="$(container_env "$container" MONGO_INITDB_DATABASE)"

  if [[ -z "$mongo_user" || -z "$mongo_pass" ]]; then
    fail "[mongodb][${project}/${service}] MONGO_INITDB_ROOT_USERNAME / PASSWORD not set — skipping"
    record_fail "$key" "MongoDB credentials not found in container env"
    return
  fi

  # Port precedence:  MONGO_PORT env override (set in .env)  >  autodetect from
  # the running mongod process (`--port N`)  >  default 27017. Autodetect covers
  # containers that listen on a non-default port (e.g. `mongod --port 27018`);
  # MONGO_PORT is the manual escape hatch for cases detection can't cover.
  local mongo_port="${MONGO_PORT:-}"
  if [[ -z "$mongo_port" ]]; then
    mongo_port="$(docker exec "$container" cat /proc/1/cmdline 2>/dev/null \
      | tr '\0' ' ' | grep -oE -- '--port[ =]+[0-9]+' | grep -oE '[0-9]+' | head -1)"
  fi
  [[ -z "$mongo_port" ]] && mongo_port=27017

  local filename="${TIMESTAMP}_${service}.archive.gz"
  local local_path="${BACKUP_TMP_DIR}/${project}_${filename}"
  local s3_key="${S3_PREFIX}/${project}/mongodb/${filename}"

  # Build mongodump args: specific DB or full dump
  local db_arg=""
  [[ -n "$mongo_db" ]] && db_arg="--db $mongo_db"

  log "[mongodb][${project}/${service}] Dumping ${mongo_db:-all databases} (port ${mongo_port})..."
  # shellcheck disable=SC2086
  if docker exec "$container" \
      mongodump \
        --port "$mongo_port" \
        --username "$mongo_user" \
        --password "$mongo_pass" \
        --authenticationDatabase admin \
        $db_arg \
        --archive --gzip \
    > "$local_path" 2>>"$LOG_FILE"; then
    local size
    size=$(stat -c%s "$local_path")
    log "[mongodb][${project}/${service}] Dump OK ($(numfmt --to=iec "$size")). Uploading..."
    if upload_to_s3 "$local_path" "$s3_key"; then
      log "[mongodb][${project}/${service}] Upload OK → s3://${S3_BUCKET}/${s3_key}"
      record_ok "$key" "$size" "$s3_key"
    else
      fail "[mongodb][${project}/${service}] S3 upload failed"
      record_fail "$key" "S3 upload failed"
    fi
  else
    fail "[mongodb][${project}/${service}] mongodump failed — see log for details"
    record_fail "$key" "mongodump failed"
  fi
  rm -f "$local_path"
}

# ─── File storage backup ──────────────────────────────────────────────────────
# Archives a directory tree (docker volume dir, bind-mount dir, uploads folder…)
# to a gzip'd tarball and uploads it to S3. Databases only cover structured data;
# apps that keep user uploads / media on disk (WordPress wp-content, upload dirs)
# need this to be fully restorable.
#
# S3 layout:  {S3_PREFIX}/{name}/filestore/{TIMESTAMP}_{name}.tar.gz
backup_filestore() {
  local name="$1" path="$2"
  local key="${name}::filestore"
  log "[filestore][${name}] Archiving ${path} ..."

  if [[ ! -e "$path" ]]; then
    fail "[filestore][${name}] Path not found: ${path}"
    record_fail "$key" "path not found: ${path}"
    return
  fi

  # Docker volume dirs live under /var/lib/docker/volumes and are root-owned.
  # If the current user cannot read the tree, fall back to passwordless sudo.
  local -a tar_cmd=(tar)
  if [[ ! -r "$path" ]]; then
    if sudo -n true 2>/dev/null; then
      tar_cmd=(sudo -n tar)
    else
      fail "[filestore][${name}] No read access to ${path} and passwordless sudo unavailable"
      record_fail "$key" "no read access (need root/sudo)"
      return
    fi
  fi

  local filename="${TIMESTAMP}_${name}.tar.gz"
  local local_path="${BACKUP_TMP_DIR}/filestore_${filename}"
  local s3_key="${S3_PREFIX}/${name}/filestore/${filename}"

  # Archive relative to the parent so the tarball has a clean top-level dir.
  local parent base
  parent="$(dirname "$path")"
  base="$(basename "$path")"

  if "${tar_cmd[@]}" -C "$parent" -czf "$local_path" "$base" 2>>"$LOG_FILE"; then
    # sudo tar leaves the file root-owned; make sure we can stat/remove it.
    [[ "${tar_cmd[0]}" == "sudo" ]] && sudo -n chown "$(id -u):$(id -g)" "$local_path" 2>/dev/null || true
    local size
    size=$(stat -c%s "$local_path")
    log "[filestore][${name}] Archive OK ($(numfmt --to=iec "$size")). Uploading..."
    if upload_to_s3 "$local_path" "$s3_key"; then
      log "[filestore][${name}] Upload OK → s3://${S3_BUCKET}/${s3_key}"
      record_ok "$key" "$size" "$s3_key"
    else
      fail "[filestore][${name}] S3 upload failed"
      record_fail "$key" "S3 upload failed"
    fi
  else
    fail "[filestore][${name}] tar failed — see log for details"
    record_fail "$key" "tar failed"
  fi
  rm -f "$local_path"
}

# Iterate the configured FILESTORE_PATHS list: "name:/path;name2:/path2;…"
backup_all_filestores() {
  [[ -z "${FILESTORE_PATHS:-}" ]] && return
  log "Processing configured file storage paths..."
  local found=0 entry name path
  local -a entries
  IFS=';' read -ra entries <<< "$FILESTORE_PATHS"
  for entry in "${entries[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"   # ltrim
    entry="${entry%"${entry##*[![:space:]]}"}"   # rtrim
    [[ -z "$entry" ]] && continue
    name="${entry%%:*}"
    path="${entry#*:}"
    if [[ -z "$name" || -z "$path" || "$name" == "$entry" ]]; then
      log "WARNING: malformed FILESTORE_PATHS entry '${entry}' (expected name:/path) — skipping"
      continue
    fi
    ((found++)) || true
    backup_filestore "$name" "$path" || true
  done
  log "Processed ${found} file storage path(s)."
}

# ─── Autodiscovery ────────────────────────────────────────────────────────────
discover_and_backup() {
  log "Discovering database containers via docker ps..."

  local found=0

  # docker ps outputs: CONTAINER_NAME <TAB> IMAGE <TAB> COMPOSE_PROJECT <TAB> COMPOSE_SERVICE
  # Containers not started by compose will have empty project/service labels.
  while IFS=$'\t' read -r container image project service; do
    # Normalize: if no compose project label, use the container name itself
    project="${project:-$container}"
    service="${service:-$container}"

    # Strip tag from image name for matching (e.g. "postgres:16" → "postgres")
    local image_name="${image%%:*}"
    # Strip registry prefix if present (e.g. "myregistry.io/postgres" → "postgres")
    image_name="${image_name##*/}"

    case "$image_name" in
      postgres)
        ((found++)) || true
        backup_postgres "$container" "$project" "$service" || true
        ;;
      mysql|mariadb)
        ((found++)) || true
        backup_mysql "$container" "$project" "$service" || true
        ;;
      *mongo*)
        ((found++)) || true
        backup_mongo "$container" "$project" "$service" || true
        ;;
    esac
  done < <(
    docker ps \
      --format $'{{.Names}}\t{{.Image}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
  )

  if [[ "$found" -eq 0 ]]; then
    log "WARNING: No database containers found. Is Docker running? Are containers up?"
  else
    log "Processed ${found} database container(s)."
  fi
}

# ─── S3 retention cleanup ────────────────────────────────────────────────────
apply_s3_retention() {
  [[ "${S3_RETENTION_DAYS:-0}" -le 0 ]] && return
  log "[retention] Removing objects older than ${S3_RETENTION_DAYS} days..."
  local cutoff
  cutoff=$(date -u -d "-${S3_RETENTION_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)

  AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}" \
  aws s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "${S3_PREFIX}/" \
    --query "Contents[?LastModified<='${cutoff}'].Key" \
    --output text \
  | tr '\t' '\n' \
  | while read -r key; do
      [[ -z "$key" || "$key" == "None" ]] && continue
      log "[retention] Deleting s3://${S3_BUCKET}/${key}"
      AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
      AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
      aws s3 rm "s3://${S3_BUCKET}/${key}" --only-show-errors
    done
}

# ─── Write status JSON ────────────────────────────────────────────────────────
write_status() {
  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build the "databases" object: one entry per discovered container
  local db_entries=""
  for key in "${!RESULT_STATUS[@]}"; do
    local status="${RESULT_STATUS[$key]}"
    local error="${RESULT_ERROR[$key]:-}"
    local size="${RESULT_SIZE[$key]:-0}"
    local s3key="${RESULT_S3KEY[$key]:-}"

    # Escape double-quotes in error string
    error="${error//\"/\\\"}"

    [[ -n "$db_entries" ]] && db_entries+=","
    db_entries+="\"${key}\":{"
    db_entries+="\"status\":\"${status}\","
    db_entries+="\"size_bytes\":${size},"
    db_entries+="\"s3_key\":\"${s3key}\","
    db_entries+="\"error\":\"${error}\""
    db_entries+="}"
  done

  # If nothing was found/processed, reflect that
  if [[ ${#RESULT_STATUS[@]} -eq 0 ]]; then
    OVERALL="failed"
    db_entries="\"_discovery\":{\"status\":\"failed\",\"size_bytes\":0,\"s3_key\":\"\",\"error\":\"No database containers discovered\"}"
  fi

  cat > "$STATUS_FILE" <<EOF
{
  "overall": "${OVERALL}",
  "timestamp": "${finished_at}",
  "run_id": "${TIMESTAMP}",
  "databases": { ${db_entries} }
}
EOF
  log "Status written → $STATUS_FILE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
log "======== Backup run ${TIMESTAMP} ========"

discover_and_backup

backup_all_filestores

apply_s3_retention || true

write_status

log "======== Done. Overall: ${OVERALL} ========"
[[ "$OVERALL" == "success" ]] && exit 0 || exit 1

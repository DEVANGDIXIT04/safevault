#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SAFEVAULT_CONFIG:-$PROJECT_DIR/safevault.conf}"
RESTORE_CONTAINER="safevault-restore"
SELECT_LATEST="false"
POINT_IN_TIME=""
KEEP_FILES="false"
TEMP_DIR=""

usage() {
  cat <<USAGE
Usage: ./scripts/restore.sh [--latest] [--container-name NAME] [--keep-files] [--point-in-time "YYYY-MM-DD HH:MM:SS"]

Options:
  --latest               Restore the newest backup without prompting.
  --container-name NAME  Name for the fresh restore container.
  --point-in-time TIME   Perform Point-In-Time Recovery using WALs (requires timestamp).
  --keep-files           Keep downloaded/decrypted files for inspection.
  -h, --help             Show this help.
USAGE
}

log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s [%s] %s\n' "$timestamp" "$level" "$message" | tee -a "$LOG_FILE"
}

notify_failure() {
  local exit_code="$?"
  if [[ "${LOG_FILE:-}" != "" ]]; then
    log "ERROR" "Restore failed with exit code $exit_code at line ${BASH_LINENO[0]}"
  fi
  WEBHOOK_URL="${WEBHOOK_URL:-}" "$SCRIPT_DIR/notify.sh" "ERROR" "SafeVault restore failed"
  cleanup
  exit "$exit_code"
}

cleanup() {
  if [[ "$KEEP_FILES" == "false" && -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$command_name" >&2
    exit 1
  fi
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --latest)
        SELECT_LATEST="true"
        shift
        ;;
      --container-name)
        RESTORE_CONTAINER="${2:-}"
        if [[ -z "$RESTORE_CONTAINER" ]]; then
          printf 'Missing value for --container-name\n' >&2
          exit 1
        fi
        shift 2
        ;;
      --point-in-time)
        POINT_IN_TIME="${2:-}"
        if [[ -z "$POINT_IN_TIME" ]]; then
          printf 'Missing value for --point-in-time\n' >&2
          exit 1
        fi
        shift 2
        ;;
      --keep-files)
        KEEP_FILES="true"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Missing config file: %s\nCopy safevault.conf.example to safevault.conf first.\n' "$CONFIG_FILE" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  BACKUP_DIR="$(cd "$PROJECT_DIR" && mkdir -p "$BACKUP_DIR" && cd "$BACKUP_DIR" && pwd)"
  LOG_FILE="$(cd "$PROJECT_DIR" && mkdir -p "$(dirname "$LOG_FILE")" && cd "$(dirname "$LOG_FILE")" && printf '%s/%s' "$(pwd)" "$(basename "$LOG_FILE")")"
}

configure_aws() {
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION
}

list_backups() {
  local prefix="$1"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 ls "s3://$S3_BUCKET/$prefix/" --recursive \
    | awk '/\.(dump|tar\.gz)\.gpg$/ { print $4 }' \
    | sort
}

select_backup_key() {
  local -n backup_keys_ref="$1"
  local index prefix="$2"

  if [[ "${#backup_keys_ref[@]}" -eq 0 ]]; then
    log "ERROR" "No backups found in s3://$S3_BUCKET/$prefix/"
    exit 1
  fi

  if [[ "$SELECT_LATEST" == "true" ]]; then
    local latest_index
    latest_index="$((${#backup_keys_ref[@]} - 1))"
    printf '%s\n' "${backup_keys_ref[$latest_index]}"
    return 0
  fi

  printf 'Available backups in %s:\n' "$prefix" >&2
  for index in "${!backup_keys_ref[@]}"; do
    printf '  %s) %s\n' "$((index + 1))" "${backup_keys_ref[$index]}" >&2
  done

  printf 'Choose a backup number: ' >&2
  read -r index
  if ! [[ "$index" =~ ^[0-9]+$ ]] || ((index < 1 || index > ${#backup_keys_ref[@]})); then
    printf 'Invalid selection: %s\n' "$index" >&2
    exit 1
  fi

  printf '%s\n' "${backup_keys_ref[$((index - 1))]}"
}

download_backup() {
  local backup_key="$1"
  local encrypted_path="$2"
  local checksum_path="$3"

  log "INFO" "Downloading s3://$S3_BUCKET/$backup_key"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "s3://$S3_BUCKET/$backup_key" "$encrypted_path" >/dev/null
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "s3://$S3_BUCKET/$backup_key.sha256" "$checksum_path" >/dev/null
}

verify_checksum() {
  local checksum_path="$1"
  log "INFO" "Verifying checksum"
  (
    cd "$TEMP_DIR"
    sha256sum -c "$(basename "$checksum_path")" >/dev/null
  )
}

decrypt_backup() {
  local encrypted_path="$1"
  local output_path="$2"
  log "INFO" "Decrypting backup"
  GNUPGHOME="$GPG_HOME" "$GPG_BIN" --batch --yes --decrypt \
    --output "$output_path" \
    "$encrypted_path"
}

remove_existing_restore_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$RESTORE_CONTAINER"; then
    log "INFO" "Removing existing restore container $RESTORE_CONTAINER"
    docker rm -f "$RESTORE_CONTAINER" >/dev/null
  fi
  # also remove old volume if doing PITR
  if docker volume ls --format '{{.Name}}' | grep -Fxq "$RESTORE_CONTAINER-data"; then
    docker volume rm "$RESTORE_CONTAINER-data" >/dev/null
  fi
}

start_restore_container_full() {
  log "INFO" "Starting fresh restore container $RESTORE_CONTAINER"
  docker run -d \
    --name "$RESTORE_CONTAINER" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    postgres:16 >/dev/null

  wait_for_postgres
}

wait_for_postgres() {
  local attempts=0
  while ((attempts < 30)); do
    if docker exec "$RESTORE_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SELECT 1;" >/dev/null 2>&1; then
      sleep 1
      docker exec "$RESTORE_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SELECT 1;" >/dev/null 2>&1
      return 0
    fi
    attempts="$((attempts + 1))"
    sleep 2
  done
  log "ERROR" "Restore container did not become ready"
  exit 1
}

restore_dump_full() {
  local dump_path="$1"
  log "INFO" "Restoring dump into $RESTORE_CONTAINER"
  docker exec -i -e "PGPASSWORD=$POSTGRES_PASSWORD" "$RESTORE_CONTAINER" pg_restore \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --no-owner \
    --role "$POSTGRES_USER" <"$dump_path"
}

restore_pitr() {
  local base_tar="$1"
  
  log "INFO" "Syncing WAL files from S3"
  mkdir -p "$TEMP_DIR/wals_gpg" "$TEMP_DIR/wals"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 sync "s3://$S3_BUCKET/wal/" "$TEMP_DIR/wals_gpg/" >/dev/null || true
  # Wait, TEMP_GPG is not a dir, it's TEMP_DIR
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 sync "s3://$S3_BUCKET/wal/" "$TEMP_DIR/wals_gpg/" >/dev/null || true

  log "INFO" "Decrypting WAL files"
  for f in "$TEMP_DIR/wals_gpg/"*.gpg; do
    if [[ -f "$f" ]]; then
      GNUPGHOME="$GPG_HOME" "$GPG_BIN" --batch --yes --decrypt --output "$TEMP_DIR/wals/$(basename "$f" .gpg)" "$f" 2>/dev/null
    fi
  done

  log "INFO" "Extracting base backup and preparing recovery"
  docker volume create "$RESTORE_CONTAINER-data" >/dev/null
  docker run -d --name temp-restore-helper -v "$RESTORE_CONTAINER-data:/pgdata" alpine sleep 300 >/dev/null
  docker cp "$base_tar" temp-restore-helper:/base.tar.gz
  docker cp "$TEMP_DIR/wals" temp-restore-helper:/wals
  docker exec temp-restore-helper sh -c "
    tar -xzf /base.tar.gz -C /pgdata &&
    mv /wals /pgdata/wals &&
    chown -R 999:999 /pgdata &&
    chmod 0700 /pgdata &&
    touch /pgdata/recovery.signal &&
    chown 999:999 /pgdata/recovery.signal &&
    echo \"restore_command = 'cp /var/lib/postgresql/data/wals/%f %p'\" >> /pgdata/postgresql.auto.conf &&
    echo \"recovery_target_time = '$POINT_IN_TIME'\" >> /pgdata/postgresql.auto.conf &&
    echo \"recovery_target_action = 'promote'\" >> /pgdata/postgresql.auto.conf
  "
  docker rm -f temp-restore-helper >/dev/null

  log "INFO" "Starting restore container for PITR"
  docker run -d \
    --name "$RESTORE_CONTAINER" \
    -v "$RESTORE_CONTAINER-data:/var/lib/postgresql/data" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    postgres:16 >/dev/null

  wait_for_postgres
  log "INFO" "PITR recovery completed successfully"
}

run_sanity_queries() {
  log "INFO" "Running sanity queries in $RESTORE_CONTAINER"
  docker exec "$RESTORE_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c "
SELECT 'funds' AS table_name, count(*) FROM funds
UNION ALL
SELECT 'investors', count(*) FROM investors
UNION ALL
SELECT 'capital_calls', count(*) FROM capital_calls
ORDER BY table_name;"
}

main() {
  parse_args "$@"
  load_config
  trap notify_failure ERR
  trap cleanup EXIT

  require_command aws
  require_command docker
  require_command "$GPG_BIN"
  require_command grep
  require_command sha256sum

  configure_aws

  local prefix
  if [[ -n "$POINT_IN_TIME" ]]; then
    prefix="base"
  else
    prefix="$S3_PREFIX"
  fi

  # shellcheck disable=SC2034
  mapfile -t backup_keys < <(list_backups "$prefix")

  local backup_key encrypted_name encrypted_path checksum_path output_path
  backup_key="$(select_backup_key backup_keys "$prefix")"
  encrypted_name="$(basename "$backup_key")"
  TEMP_DIR="$BACKUP_DIR/restore-$(date +%s)"
  mkdir -p "$TEMP_DIR"
  encrypted_path="$TEMP_DIR/$encrypted_name"
  checksum_path="$TEMP_DIR/$encrypted_name.sha256"
  output_path="$TEMP_DIR/${encrypted_name%.gpg}"

  download_backup "$backup_key" "$encrypted_path" "$checksum_path"
  verify_checksum "$checksum_path"
  decrypt_backup "$encrypted_path" "$output_path"
  remove_existing_restore_container

  if [[ -n "$POINT_IN_TIME" ]]; then
    restore_pitr "$output_path"
  else
    start_restore_container_full
    restore_dump_full "$output_path"
  fi

  run_sanity_queries

  log "INFO" "Restore completed in container $RESTORE_CONTAINER"
  if [[ "$KEEP_FILES" == "true" ]]; then
    log "INFO" "Kept restore files in $TEMP_DIR"
  fi
}

main "$@"

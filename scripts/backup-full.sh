#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SAFEVAULT_CONFIG:-$PROJECT_DIR/safevault.conf}"

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
  log "ERROR" "Full backup failed with exit code $exit_code at line ${BASH_LINENO[0]}"
  WEBHOOK_URL="${WEBHOOK_URL:-}" "$SCRIPT_DIR/notify.sh" "ERROR" "SafeVault full backup failed"
  exit "$exit_code"
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    log "ERROR" "Missing required command: $command_name"
    exit 1
  fi
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

ensure_bucket() {
  if ! aws --endpoint-url "$S3_ENDPOINT_URL" s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    log "INFO" "Creating S3 bucket s3://$S3_BUCKET"
    aws --endpoint-url "$S3_ENDPOINT_URL" s3api create-bucket --bucket "$S3_BUCKET" >/dev/null
  fi
}

make_dump() {
  local output_path="$1"
  log "INFO" "Running pg_dump custom compressed backup for $POSTGRES_DB"
  docker exec -e "PGPASSWORD=$POSTGRES_PASSWORD" "$POSTGRES_CONTAINER" pg_dump \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --format custom \
    --compress 9 >"$output_path"
}

encrypt_backup() {
  local input_path="$1"
  local encrypted_path="$2"
  log "INFO" "Encrypting backup for GPG recipient $GPG_RECIPIENT"
  GNUPGHOME="$GPG_HOME" "$GPG_BIN" --batch --yes --trust-model always \
    --recipient "$GPG_RECIPIENT" \
    --encrypt \
    --output "$encrypted_path" \
    "$input_path"
}

write_checksum() {
  local encrypted_path="$1"
  local checksum_path="$2"
  sha256sum "$(basename "$encrypted_path")" >"$checksum_path"
}

upload_and_verify() {
  local encrypted_path="$1"
  local checksum_path="$2"
  local encrypted_name checksum_name remote_base
  encrypted_name="$(basename "$encrypted_path")"
  checksum_name="$(basename "$checksum_path")"
  remote_base="s3://$S3_BUCKET/$S3_PREFIX"

  log "INFO" "Uploading $encrypted_name and $checksum_name to $remote_base"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "$encrypted_path" "$remote_base/$encrypted_name" >/dev/null
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "$checksum_path" "$remote_base/$checksum_name" >/dev/null

  local temp_dir
  temp_dir="$(mktemp -d)"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "$remote_base/$checksum_name" "$temp_dir/$checksum_name" >/dev/null
  cmp "$checksum_path" "$temp_dir/$checksum_name" >/dev/null
  rm -rf "$temp_dir"

  log "INFO" "Verified uploaded checksum for $encrypted_name"
}

prune_old_local_backups() {
  log "INFO" "Pruning local full backups older than $RETENTION_DAYS days"
  find "$BACKUP_DIR" -type f -name 'safevault-full-*' -mtime "+$RETENTION_DAYS" -print -delete
}

main() {
  load_config
  trap notify_failure ERR

  require_command aws
  require_command docker
  require_command "$GPG_BIN"
  require_command sha256sum

  configure_aws
  ensure_bucket

  local timestamp dump_path encrypted_path checksum_path
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  dump_path="$BACKUP_DIR/safevault-full-$timestamp.dump"
  encrypted_path="$dump_path.gpg"
  checksum_path="$encrypted_path.sha256"

  make_dump "$dump_path"
  encrypt_backup "$dump_path" "$encrypted_path"
  (
    cd "$BACKUP_DIR"
    write_checksum "$encrypted_path" "$checksum_path"
  )
  upload_and_verify "$encrypted_path" "$checksum_path"
  rm -f "$dump_path"
  prune_old_local_backups

  log "INFO" "Full backup completed: $(basename "$encrypted_path")"
}

main "$@"

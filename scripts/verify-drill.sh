#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SAFEVAULT_CONFIG:-$PROJECT_DIR/safevault.conf}"
DRILL_CONTAINER="safevault-drill"
TEMP_DIR=""
PREPARED_DUMP_PATH=""

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
    log "ERROR" "DR drill failed with exit code $exit_code at line ${BASH_LINENO[0]}"
  fi
  WEBHOOK_URL="${WEBHOOK_URL:-}" "$SCRIPT_DIR/notify.sh" "ERROR" "SafeVault DR drill failed"
  cleanup
  exit "$exit_code"
}

cleanup() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$DRILL_CONTAINER"; then
    docker rm -f "$DRILL_CONTAINER" >/dev/null
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
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

latest_backup_key() {
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 ls "s3://$S3_BUCKET/$S3_PREFIX/" --recursive \
    | awk '/\.dump\.gpg$/ { print $4 }' \
    | sort \
    | tail -n 1
}

download_and_prepare_dump() {
  local backup_key="$1"
  local encrypted_name encrypted_path checksum_path dump_path
  encrypted_name="$(basename "$backup_key")"
  TEMP_DIR="$(mktemp -d "$BACKUP_DIR/drill.XXXXXX")"
  encrypted_path="$TEMP_DIR/$encrypted_name"
  checksum_path="$TEMP_DIR/$encrypted_name.sha256"
  dump_path="$TEMP_DIR/${encrypted_name%.gpg}"

  log "INFO" "Downloading latest backup $backup_key"
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "s3://$S3_BUCKET/$backup_key" "$encrypted_path" >/dev/null
  aws --endpoint-url "$S3_ENDPOINT_URL" s3 cp "s3://$S3_BUCKET/$backup_key.sha256" "$checksum_path" >/dev/null

  log "INFO" "Verifying checksum"
  (
    cd "$TEMP_DIR"
    sha256sum -c "$(basename "$checksum_path")" >/dev/null
  )

  log "INFO" "Decrypting backup"
  GNUPGHOME="$GPG_HOME" "$GPG_BIN" --batch --yes --decrypt \
    --output "$dump_path" \
    "$encrypted_path"

  PREPARED_DUMP_PATH="$dump_path"
}

remove_existing_drill_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "$DRILL_CONTAINER"; then
    log "INFO" "Removing existing drill container $DRILL_CONTAINER"
    docker rm -f "$DRILL_CONTAINER" >/dev/null
  fi
}

start_drill_container() {
  log "INFO" "Starting throwaway drill container $DRILL_CONTAINER"
  docker run -d \
    --name "$DRILL_CONTAINER" \
    -e "POSTGRES_DB=$POSTGRES_DB" \
    -e "POSTGRES_USER=$POSTGRES_USER" \
    -e "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
    postgres:16 >/dev/null

  local attempts
  attempts=0
  while ((attempts < 30)); do
    if docker exec "$DRILL_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SELECT 1;" >/dev/null 2>&1; then
      sleep 1
      docker exec "$DRILL_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At -c "SELECT 1;" >/dev/null 2>&1
      return 0
    fi
    attempts="$((attempts + 1))"
    sleep 2
  done

  log "ERROR" "Drill container did not become ready after $attempts attempts"
  exit 1
}

restore_dump() {
  local dump_path="$1"
  log "INFO" "Restoring dump into $DRILL_CONTAINER"
  docker exec -i -e "PGPASSWORD=$POSTGRES_PASSWORD" "$DRILL_CONTAINER" pg_restore \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --no-owner \
    --role "$POSTGRES_USER" <"$dump_path" || log "WARN" "pg_restore returned non-zero (warnings likely)"
}

table_counts() {
  local container_name="$1"
  docker exec "$container_name" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -At -c "
SELECT 'funds=' || count(*) FROM funds
UNION ALL
SELECT 'investors=' || count(*) FROM investors
UNION ALL
SELECT 'capital_calls=' || count(*) FROM capital_calls
ORDER BY 1;"
}

main() {
  load_config
  trap notify_failure ERR
  trap cleanup EXIT

  require_command aws
  require_command docker
  require_command "$GPG_BIN"
  require_command grep
  require_command sha256sum

  configure_aws

  local backup_key production_counts restore_counts
  backup_key="$(latest_backup_key)"
  if [[ -z "$backup_key" ]]; then
    log "ERROR" "No full backups found in s3://$S3_BUCKET/$S3_PREFIX/"
    exit 1
  fi

  production_counts="$(table_counts "$POSTGRES_CONTAINER")"
  download_and_prepare_dump "$backup_key"
  remove_existing_drill_container
  start_drill_container
  restore_dump "$PREPARED_DUMP_PATH"
  restore_counts="$(table_counts "$DRILL_CONTAINER")"

  printf 'Production counts:\n%s\n' "$production_counts"
  printf 'Restored counts:\n%s\n' "$restore_counts"

  if [[ "$production_counts" == "$restore_counts" ]]; then
    log "INFO" "DR drill PASS"
    printf 'PASS: restored counts match production.\n'
    if [[ -n "${WEBHOOK_URL:-}" ]]; then
      "$SCRIPT_DIR/notify.sh" "INFO" "SafeVault DR drill completed successfully. Restored counts match production."
    fi
  else
    log "ERROR" "DR drill FAIL"
    printf 'FAIL: restored counts do not match production.\n' >&2
    exit 1
  fi
}

main "$@"

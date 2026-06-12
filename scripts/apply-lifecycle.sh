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
  printf '%s [%s] %s\n' "$timestamp" "$level" "$message"
}

notify_failure() {
  local exit_code="$?"
  log "ERROR" "Failed to apply S3 lifecycle policy with exit code $exit_code"
  WEBHOOK_URL="${WEBHOOK_URL:-}" "$SCRIPT_DIR/notify.sh" "ERROR" "SafeVault lifecycle policy application failed"
  exit "$exit_code"
}

main() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Missing config file: %s\n' "$CONFIG_FILE" >&2
    exit 1
  fi
  source "$CONFIG_FILE"
  trap notify_failure ERR

  local policy_file="$PROJECT_DIR/lifecycle-policy.json"
  
  if [[ ! -f "$policy_file" ]]; then
    log "ERROR" "Lifecycle policy file not found at $policy_file"
    exit 1
  fi

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION

  log "INFO" "Applying lifecycle configuration from $policy_file to s3://$S3_BUCKET"
  
  (
    cd "$PROJECT_DIR"
    aws --endpoint-url "$S3_ENDPOINT_URL" s3api put-bucket-lifecycle-configuration \
      --bucket "$S3_BUCKET" \
      --lifecycle-configuration "file://lifecycle-policy.json"
  )

  log "INFO" "Lifecycle configuration applied successfully"
  
  if [[ -n "${WEBHOOK_URL:-}" ]]; then
    "$SCRIPT_DIR/notify.sh" "INFO" "SafeVault lifecycle policy applied successfully"
  fi
}

main "$@"

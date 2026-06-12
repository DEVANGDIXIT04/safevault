#!/usr/bin/env bash
set -euo pipefail

main() {
  local level="${1:-INFO}"
  local message="${2:-SafeVault notification}"
  local webhook_url="${WEBHOOK_URL:-}"

  if [[ -z "$webhook_url" ]]; then
    return 0
  fi

  curl -fsS \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"[$level] $message\"}" \
    "$webhook_url" >/dev/null
}

main "$@"


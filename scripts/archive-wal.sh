#!/usr/bin/env bash
set -euo pipefail

WAL_PATH="$1"
WAL_FILE="$2"

# Ensure we load configuration
# shellcheck source=/dev/null
source /etc/safevault.conf

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION

# Fix S3 endpoint for container context
CONTAINER_S3_ENDPOINT="${S3_ENDPOINT_URL/localhost/safevault-minio}"

TEMP_GPG="/tmp/${WAL_FILE}.gpg"

# Encrypt WAL file directly. Trust model always is used for automated processes.
gpg --batch --yes --trust-model always --recipient "$GPG_RECIPIENT" --encrypt --output "$TEMP_GPG" "$WAL_PATH"

# Upload to S3
aws --endpoint-url "$CONTAINER_S3_ENDPOINT" s3 cp "$TEMP_GPG" "s3://$S3_BUCKET/wal/$WAL_FILE.gpg" >/dev/null

# Clean up
rm -f "$TEMP_GPG"

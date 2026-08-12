#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPOSE_FILE="$ROOT/Integration/docker-compose.yml"
export COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-"s3workbench-integration-$$"}
export MINIO_API_PORT=${MINIO_API_PORT:-19000}
export MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT:-19001}
export MINIO_ROOT_USER=${MINIO_ROOT_USER:-s3workbench}
export MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-s3workbench-secret}
export MINIO_TEST_BUCKET=${MINIO_TEST_BUCKET:-s3workbench-tests}

compose=(docker compose -f "$COMPOSE_FILE")
cleanup() {
  if [[ ${KEEP_MINIO:-0} != 1 ]]; then "${compose[@]}" down --volumes --remove-orphans >/dev/null; fi
}
trap cleanup EXIT

"${compose[@]}" up -d minio
"${compose[@]}" run --rm minio-init

export S3_INTEGRATION_TESTS=1
export S3_TEST_ENDPOINT="http://127.0.0.1:$MINIO_API_PORT"
export S3_TEST_ACCESS_KEY="$MINIO_ROOT_USER"
export S3_TEST_SECRET_KEY="$MINIO_ROOT_PASSWORD"
export S3_TEST_REGION=us-east-1
export S3_TEST_BUCKET="$MINIO_TEST_BUCKET"
export S3_TEST_ADDRESSING_STYLE=path
export S3_TEST_TLS_VERIFY=1
export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_REGION=us-east-1
export AWS_EC2_METADATA_DISABLED=true

"${compose[@]}" run --rm --entrypoint /bin/sh minio-init -c '
  set -eu
  mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 --path on >/dev/null
  key="prefix with spaces/ünicode-雪.txt"
  printf "S3Workbench integration payload" | mc pipe "local/$MINIO_TEST_BUCKET/$key" >/dev/null
  test "$(mc cat "local/$MINIO_TEST_BUCKET/$key")" = "S3Workbench integration payload"
  mc stat "local/$MINIO_TEST_BUCKET/$key" >/dev/null
  mc od if=/dev/zero "of=local/$MINIO_TEST_BUCKET/multipart-10MiB.bin" size=5MiB parts=2 >/dev/null
  multipart_stat=$(mc stat "local/$MINIO_TEST_BUCKET/multipart-10MiB.bin")
  case "$multipart_stat" in *"10 MiB"*) ;; *) exit 1 ;; esac
  mc rm "local/$MINIO_TEST_BUCKET/$key" "local/$MINIO_TEST_BUCKET/multipart-10MiB.bin" >/dev/null
'
echo "MinIO fixture smoke checks passed"

swift test --package-path "$ROOT"

echo "Swift and MinIO integration checks passed at $S3_TEST_ENDPOINT"

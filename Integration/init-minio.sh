#!/bin/sh
set -eu

mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 --path on >/dev/null
mc mb --ignore-existing "local/$MINIO_TEST_BUCKET" >/dev/null
mc mb --ignore-existing "local/$MINIO_TEST_BUCKET-forbidden" >/dev/null
mc admin user add local "$MINIO_RESTRICTED_USER" "$MINIO_RESTRICTED_PASSWORD" >/dev/null
while IFS= read -r line; do
  case "$line" in
    *__BUCKET__*)
      prefix=${line%%__BUCKET__*}
      suffix=${line#*__BUCKET__}
      printf '%s%s%s\n' "$prefix" "$MINIO_TEST_BUCKET" "$suffix"
      ;;
    *) printf '%s\n' "$line" ;;
  esac
done </restricted-policy.json >/tmp/restricted-policy.json
mc admin policy create local s3workbench-restricted /tmp/restricted-policy.json >/dev/null
mc admin policy attach local s3workbench-restricted --user "$MINIO_RESTRICTED_USER" >/dev/null
mc ready local >/dev/null

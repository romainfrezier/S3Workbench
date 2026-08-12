#!/bin/sh
set -eu

mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 --path on >/dev/null
mc mb --ignore-existing "local/$MINIO_TEST_BUCKET" >/dev/null
mc ready local >/dev/null

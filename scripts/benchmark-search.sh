#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export S3_SEARCH_BENCHMARK_OBJECTS=${S3_SEARCH_BENCHMARK_OBJECTS:-100000}

swift test --package-path "$ROOT" --filter searchIndexBenchmark

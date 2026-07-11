#!/usr/bin/env bash
# new-api 一键启动（Docker Compose）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/scripts/deploy.sh" "$@"

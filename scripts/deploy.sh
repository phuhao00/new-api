#!/usr/bin/env bash
# new-api 一键部署脚本（Linux / macOS）
#
# 用法:
#   ./scripts/deploy.sh              # Docker Compose 一键启动
#   ./scripts/deploy.sh --stop       # 停止服务
#   ./scripts/deploy.sh --build      # 使用本地源码构建（docker-compose.dev.yml）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="prod"
STOP=0

for arg in "$@"; do
  case "$arg" in
    --stop|-s) STOP=1 ;;
    --build|--dev) MODE="dev" ;;
    --help|-h)
      cat <<'EOF'
new-api 一键部署

  ./scripts/deploy.sh           Docker Compose 生产镜像启动
  ./scripts/deploy.sh --build   本地源码构建开发栈（postgres + redis + api）
  ./scripts/deploy.sh --stop    停止对应服务

访问地址: http://localhost:3000/
EOF
      exit 0
      ;;
    *)
      echo "[deploy] 未知参数: $arg" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "[deploy] 未找到 docker，请先安装 Docker" >&2
  exit 1
fi

COMPOSE_FILE="docker-compose.yml"
if [[ "$MODE" == "dev" ]]; then
  COMPOSE_FILE="docker-compose.dev.yml"
fi

if [[ "$STOP" -eq 1 ]]; then
  echo "[deploy] 停止服务 ($COMPOSE_FILE)..."
  docker compose -f "$COMPOSE_FILE" down
  echo "[ok] 已停止"
  exit 0
fi

mkdir -p data logs

echo "[deploy] 启动服务 ($COMPOSE_FILE)..."
docker compose -f "$COMPOSE_FILE" up -d --build

echo "[deploy] 等待健康检查..."
ok=0
for i in $(seq 1 45); do
  if curl -fsS "http://localhost:3000/api/status" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done

if [[ "$ok" -eq 1 ]]; then
  echo "[ok] 部署成功"
  echo
  echo "  访问地址: http://localhost:3000/"
  echo "  数据目录: $ROOT/data"
  echo "  停止服务: ./scripts/deploy.sh --stop$([ "$MODE" = "dev" ] && echo " --build")"
else
  echo "[warn] 容器已启动，但健康检查尚未通过，请稍后访问 http://localhost:3000/"
  docker compose -f "$COMPOSE_FILE" ps
fi

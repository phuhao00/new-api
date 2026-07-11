#!/usr/bin/env bash
# new-api 一键部署脚本（Linux / macOS）
#
# 默认会：用本地 Dockerfile 构建镜像 → 启动 → 等待健康检查 → 同步 Bony 品牌到数据库
#
# 用法:
#   ./scripts/deploy.sh                 # 构建并启动（推荐）
#   ./scripts/deploy.sh --no-build      # 不重建镜像，仅 up -d + 同步品牌
#   ./scripts/deploy.sh --no-sync-brand # 跳过品牌写入
#   ./scripts/deploy.sh --build         # 使用 docker-compose.dev.yml
#   ./scripts/deploy.sh --stop          # 停止服务
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="prod"
STOP=0
DO_BUILD=1
SYNC_BRAND=1
API_PORT=3000
MAX_WAIT_SECONDS=120

# 站点品牌（写入 options 表，覆盖库里残留的 New API）
BRAND_NAME="${BRAND_NAME:-Bony API}"
BRAND_LOGO="${BRAND_LOGO:-/logo-bony.png}"
BRAND_FOOTER="${BRAND_FOOTER:-Bony API}"

for arg in "$@"; do
  case "$arg" in
    --stop|-s) STOP=1 ;;
    --build|--dev) MODE="dev" ;;
    --no-build) DO_BUILD=0 ;;
    --no-sync-brand) SYNC_BRAND=0 ;;
    --help|-h)
      cat <<'EOF'
new-api 一键部署

  ./scripts/deploy.sh              本地 Dockerfile 构建 + 启动 + 同步 Bony 品牌
  ./scripts/deploy.sh --no-build   不重建镜像，仅重启/启动并同步品牌
  ./scripts/deploy.sh --no-sync-brand  跳过品牌写入（保留库里现有站点名/Logo）
  ./scripts/deploy.sh --build      开发栈（docker-compose.dev.yml）
  ./scripts/deploy.sh --stop       停止对应服务

环境变量（可选）:
  BRAND_NAME / BRAND_LOGO / BRAND_FOOTER  覆盖默认品牌文案

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

COMPOSE_FILE="docker-compose.yml"
CONTAINER_NAME="new-api"
if [[ "$MODE" == "dev" ]]; then
  COMPOSE_FILE="docker-compose.dev.yml"
  CONTAINER_NAME="new-api-dev"
fi

free_port() {
  local port="$1"
  local pids
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  elif command -v fuser >/dev/null 2>&1; then
    fuser -k "${port}/tcp" 2>/dev/null || true
    return 0
  else
    return 0
  fi
  if [[ -n "${pids}" ]]; then
    echo "[deploy] 端口 ${port} 被占用 (${pids})，正在结束进程..."
    # shellcheck disable=SC2086
    kill -9 ${pids} 2>/dev/null || true
    sleep 0.5
  fi
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo "[deploy] 未找到 docker，请先安装 Docker" >&2
  exit 1
}

# 防止误用官方镜像：拉代码却不重建会导致线上仍是 New API
ensure_local_compose() {
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "[deploy] 缺少 $COMPOSE_FILE" >&2
    exit 1
  fi
  if grep -qE 'image:\s*calciumion/new-api' "$COMPOSE_FILE"; then
    echo "[deploy] 错误: $COMPOSE_FILE 仍使用官方镜像 calciumion/new-api" >&2
    echo "[deploy] 请 git pull 最新代码（应改为 build 本地 Dockerfile / image: new-api:local）" >&2
    exit 1
  fi
  if [[ "$MODE" == "prod" ]] && ! grep -qE '^\s*build:' "$COMPOSE_FILE"; then
    echo "[deploy] 错误: $COMPOSE_FILE 未配置 build，无法把本地品牌改动打进镜像" >&2
    exit 1
  fi
}

wait_for_api() {
  local port="$1"
  local max_wait="$2"
  local i=0
  local code=""

  echo "[deploy] 等待 API 就绪（最多 ${max_wait}s）: http://localhost:${port}/api/status"

  while [[ "$i" -lt "$max_wait" ]]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 2 \
      "http://127.0.0.1:${port}/api/status" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      echo "[ok] API 已就绪 (${i}s)"
      return 0
    fi

    i=$((i + 1))
    if (( i % 5 == 0 )); then
      echo "[deploy] 仍在等待... ${i}/${max_wait}s (HTTP=${code:-000})"
      if (( i % 15 == 0 )); then
        echo "[deploy] 提示: docker logs ${CONTAINER_NAME} --tail 20"
      fi
    fi
    sleep 1
  done

  echo "[warn] ${max_wait}s 内未通过健康检查"
  echo "[deploy] 容器状态:"
  docker compose -f "$COMPOSE_FILE" ps || true
  echo "[deploy] ${CONTAINER_NAME} 最近日志:"
  docker logs "$CONTAINER_NAME" --tail 40 2>/dev/null || docker compose -f "$COMPOSE_FILE" logs --tail 40 new-api || true
  return 1
}

# 把品牌写入 Postgres options，并重启 API 使内存配置立即生效
sync_brand() {
  local pg_container="postgres"
  if ! docker ps --format '{{.Names}}' | grep -qx "$pg_container"; then
    echo "[warn] 未找到 postgres 容器，跳过品牌同步"
    return 0
  fi

  echo "[deploy] 同步站点品牌: name=${BRAND_NAME} logo=${BRAND_LOGO}"

  local name_sql logo_sql footer_sql
  name_sql="${BRAND_NAME//\'/\'\'}"
  logo_sql="${BRAND_LOGO//\'/\'\'}"
  footer_sql="${BRAND_FOOTER//\'/\'\'}"

  # key 在 PostgreSQL 中为保留字，需双引号
  docker exec -i "$pg_container" psql -U root -d new-api -v ON_ERROR_STOP=1 <<SQL
INSERT INTO options ("key", value) VALUES ('SystemName', '${name_sql}')
  ON CONFLICT ("key") DO UPDATE SET value = EXCLUDED.value;
INSERT INTO options ("key", value) VALUES ('Logo', '${logo_sql}')
  ON CONFLICT ("key") DO UPDATE SET value = EXCLUDED.value;
INSERT INTO options ("key", value) VALUES ('Footer', '${footer_sql}')
  ON CONFLICT ("key") DO UPDATE SET value = EXCLUDED.value;
SQL

  echo "[deploy] 重启 ${CONTAINER_NAME} 以加载品牌配置..."
  docker compose -f "$COMPOSE_FILE" restart new-api
  wait_for_api "$API_PORT" 60 || true

  local status_json
  status_json="$(curl -s --connect-timeout 2 --max-time 5 "http://127.0.0.1:${API_PORT}/api/status" 2>/dev/null || true)"
  if echo "$status_json" | grep -q "\"system_name\":\"${BRAND_NAME}\""; then
    echo "[ok] 品牌已生效: ${BRAND_NAME}"
  elif echo "$status_json" | grep -q 'system_name'; then
    echo "[warn] /api/status 中的 system_name 可能尚未刷新，请强制刷新浏览器缓存"
    echo "[deploy] 当前 status 片段: $(echo "$status_json" | tr -d '\n' | head -c 200)"
  else
    echo "[warn] 无法校验品牌，请打开后台「系统设置」确认站点名称/Logo"
  fi
}

print_image_hint() {
  local img
  img="$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [[ -n "$img" ]]; then
    echo "[deploy] 当前镜像: $img"
    if [[ "$img" == *calciumion/new-api* ]]; then
      echo "[warn] 仍在使用官方镜像！请确认已 git pull 且执行了带 --build 的部署" >&2
    fi
  fi
}

ensure_docker
ensure_local_compose

if [[ "$STOP" -eq 1 ]]; then
  echo "[deploy] 停止服务 ($COMPOSE_FILE)..."
  docker compose -f "$COMPOSE_FILE" down
  echo "[ok] 已停止"
  exit 0
fi

mkdir -p data logs
free_port "$API_PORT"

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "[deploy] 构建并启动服务 ($COMPOSE_FILE)..."
  echo "[deploy] 说明: 首次/改前端后构建可能需要几分钟，请耐心等待"
  docker compose -f "$COMPOSE_FILE" up -d --build
else
  echo "[deploy] 启动服务（跳过 build）($COMPOSE_FILE)..."
  docker compose -f "$COMPOSE_FILE" up -d
fi

print_image_hint

if ! wait_for_api "$API_PORT" "$MAX_WAIT_SECONDS"; then
  echo "[warn] 容器可能仍在启动中，请稍后访问 http://localhost:${API_PORT}/"
  echo "[deploy] 排查: docker logs ${CONTAINER_NAME} --tail 80"
  exit 1
fi

if [[ "$SYNC_BRAND" -eq 1 ]]; then
  sync_brand
fi

echo "[ok] 部署成功"
echo
echo "  访问地址: http://localhost:${API_PORT}/"
echo "  站点名称: ${BRAND_NAME}"
echo "  Logo:     ${BRAND_LOGO}"
echo "  数据目录: $ROOT/data"
echo "  停止服务: ./scripts/deploy.sh --stop$([ "$MODE" = "dev" ] && echo " --build")"
echo
echo "  若浏览器仍显示 New API：强制刷新（Ctrl+F5）或清除该站 localStorage"
exit 0

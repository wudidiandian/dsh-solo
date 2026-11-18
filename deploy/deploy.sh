#!/usr/bin/env sh
# dsh-solo relay 一键部署（Docker Compose：relay + Caddy 自动 TLS）
#
# 用法（在服务器上克隆仓库后执行）：
#   ./deploy/deploy.sh <你的域名>
# 例：
#   ./deploy/deploy.sh relay.example.com
#
# 前置：
#   - 服务器已安装 Docker（含 compose 插件）：curl -fsSL https://get.docker.com | sh
#   - 域名 A 记录已解析到本机公网 IP
#   - 防火墙/安全组放行 80、443（8787 无需对公网开放）
#
# 幂等：重复执行即更新重建；换域名后重新执行即可切换。
set -eu
cd "$(dirname "$0")/.."

DOMAIN="${1:?用法: ./deploy/deploy.sh <relay-domain>}"
case "$DOMAIN" in
  *[!a-zA-Z0-9.-]*) echo "无效域名: $DOMAIN" >&2; exit 1 ;;
  *) ;;
esac

# 1. 生成 compose 环境变量（Caddy 据此申请证书）
mkdir -p .generated
printf 'RELAY_DOMAIN=%s\n' "$DOMAIN" > .generated/deploy.env

# 2. 构建并启动（relay 只映射到宿主回环，公网入口统一走 Caddy WSS）
echo "==> 构建并启动 relay + Caddy（域名: $DOMAIN）"
docker compose --env-file .generated/deploy.env -f deploy/docker-compose.yml up -d --build

# 3. 等待 relay 容器健康
echo "==> 等待 relay 就绪…"
i=0
until curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 30 ]; then
    echo "relay 未就绪，查看日志: docker compose -f deploy/docker-compose.yml logs relay" >&2
    exit 1
  fi
  sleep 2
done
echo "==> relay 容器健康"

# 4. 公网 WSS 验证（Caddy 首次签发证书约需 10-30 秒）
echo "==> 等待 Caddy 签发 TLS 证书…"
i=0
while [ "$i" -lt 60 ]; do
  if curl -fsS "https://$DOMAIN/healthz" >/dev/null 2>&1; then
    echo "==> 部署完成，网关地址: wss://$DOMAIN/ws"
    exit 0
  fi
  i=$((i + 1))
  sleep 3
done
echo "==> 公网健康检查未通过（证书可能仍在签发或 80/443 未放行），" \
  "稍后手动验证: curl https://$DOMAIN/healthz" >&2
exit 1

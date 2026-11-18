# 不推代码的服务器测试部署（本地构建镜像 → scp → docker load）

适用：改动未推送 GitHub（避免影响 main 分支其他人），先把 relay 镜像在本地构建好传服务器验证。

## 0. 前置（一次性）

- 本机安装并启动 Docker Desktop（构建 linux/amd64 镜像，Windows 默认即可）
- 服务器装 Docker：`curl -fsSL https://get.docker.com | sh`
- 域名解析已生效；服务器防火墙放行 80、443
- 服务器上旧 systemd relay / Caddy 已停（避免占用 80/443/8787）：
  `sudo systemctl stop relay caddy && sudo systemctl disable relay caddy`

## 1. 本地：构建镜像并打包（仓库根目录执行）

```powershell
docker build -f deploy/Dockerfile.relay -t dsh-solo/relay:latest .
docker save dsh-solo/relay:latest | gzip > dsh-relay-image.tar.gz
# 产出约 6MB
```

## 2. 上传 3 个文件到服务器

```powershell
scp dsh-relay-image.tar.gz <用户>@<服务器IP>:/opt/dsh-solo/
scp deploy/docker-compose.image.yml deploy/Caddyfile.docker <用户>@<服务器IP>:/opt/dsh-solo/
```

## 3. 服务器：导入镜像并启动

```bash
cd /opt/dsh-solo
docker load -i dsh-relay-image.tar.gz
printf 'RELAY_DOMAIN=relay.example.com\n' > .env
docker compose -f docker-compose.image.yml --env-file .env up -d

# 观察：relay 健康 + Caddy 拉起
docker compose -f docker-compose.image.yml ps
docker logs -f $(docker compose -f docker-compose.image.yml ps -q caddy)   # 看证书签发
```

## 4. 验证

```bash
# 服务器本机
curl -s http://127.0.0.1:8787/healthz    # → ok

# 任意机器（验证 DNS + TLS + 反代链路）
curl https://relay.example.com/healthz    # → ok
```

看到 `ok` 后，使用配置了相同网关地址的 App 与插件进行测试；其他服务器同样流程，`.env` 中填写对应域名。

## 后续更新镜像

重复 1、2 步，服务器上：

```bash
cd /opt/dsh-solo
docker load -i dsh-relay-image.tar.gz
docker compose -f docker-compose.image.yml --env-file .env up -d --force-recreate relay
```

## 与正式方案的关系

测试通过、代码定稿后，推送到 GitHub，服务器改用正式一键脚本（`./deploy/deploy.sh <域名>`，从源码构建），本目录的临时文件即可删除。

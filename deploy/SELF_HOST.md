# 自建部署指南（Self-Hosting / BYOS）

> 自建（Bring Your Own Server）是 DSH-SOLO 的**永久免费路线**：全部流量走你自己的服务器，功能无任何阉割，数据不过任何第三方。这正是本项目"Local-First"承诺的核心。

三种接入姿势按你的网络条件选其一：

| 姿势 | 适用场景 | 需要什么 |
|---|---|---|
| **A. VPS + 域名（WSS）** | 正式使用，多设备多用户 | 有公网 IP 的服务器 + 一个已备案/境外域名 |
| **B. Cloudflare Tunnel** | 无公网 IP（家宽 NAT 后）、不想开端口、免备案 | 一台电脑 + Cloudflare 账号 + 一个域名（托管到 CF） |
| **C. Tailscale / 内网直连** | 同一局域网，或个人组网，极致隐私 | 电脑与手机装 Tailscale（或同 Wi-Fi 直连） |

relay 的连接模型：`App ↔ relay ↔ agent 插件`，两端用相同 deviceToken 配对。relay 是唯一需要公网可达的组件（姿势 B/C 除外）。

---

## 姿势 A：VPS + 域名（Docker Compose 一键部署，推荐）

适合：有自己的 VPS 和域名，想给多设备/朋友长期使用。

### A1. 准备

- 一台 VPS（1C1G 起步即可），已装 Docker（`curl -fsSL https://get.docker.com | sh`）
- 一个域名，A 记录指向 VPS IP

### A2. 部署（一键脚本，推荐）

```bash
git clone https://github.com/wudidiandian/dsh-solo.git
cd dsh-solo
./deploy/deploy.sh <你的域名>      # 例如 ./deploy/deploy.sh relay.example.com
# 脚本自动：生成 compose 环境变量 → 构建启动 relay+Caddy → 等待健康 → 验证 https 证书
# 成功后网关地址即：wss://<你的域名>/ws
```

脚本幂等：换域名、更新代码后重新执行 `./deploy/deploy.sh <域名>` 即可。

<details>
<summary>手动分步执行（等价于脚本内做的事）</summary>

```bash
# 1. 复制统一配置，填入自己的 relayUrl 与 relayDomain
cp config/distribution.example.json config/distribution.local.json
# 编辑 config/distribution.local.json 后生成配置（需要 Node.js）
node scripts/configure.mjs
# 2. 起服务
docker compose --env-file .generated/deploy.env -f deploy/docker-compose.yml up -d --build
# 3. 验证
curl https://<你的域名>/healthz     # → ok
```

</details>

Caddy 自动申请并续期 Let's Encrypt 证书（要求 80/443 公网可达，防火墙放行这两个端口；**8787 无需对公网开放**，compose 里已只映射到宿主回环）。

> 多节点部署：在不同服务器上分别执行上述脚本、各自填自己的域名即可（例如国内备案域名一台、海外域名一台）。App 内置了网关选择，可在「连接设置」中切换国内/国际节点；电脑端插件的 `relayUrl` 需与所选节点一致。

### A.2 二进制直跑（不想用 Docker）

```bash
# 下载或自行交叉编译（见 README）
go build -C server -o relay ./cmd/relay
sudo mv relay /opt/dsh-solo/relay && sudo chmod 755 /opt/dsh-solo/relay
# systemd 常驻模板见 deploy/relay.service（改 ExecStart 路径与参数后）：
sudo systemctl daemon-reload && sudo systemctl enable --now relay
# 然后 手动安装 Caddy 并配置 deploy/Caddyfile
```

---

## 姿势 B：Cloudflare Tunnel（免公网 IP、免备案、免开端口）

适合：电脑/服务器在家宽 NAT 后，或不方便开 80/443 端口。**流量过 Cloudflare 边缘，域名免备案。**

1. 先按 A2 生成配置，再运行 relay；使用二进制时仅监听本机：
   ```bash
   docker compose --env-file .generated/deploy.env -f deploy/docker-compose.yml up -d relay
   # 或裸跑：go run -C server ./cmd/relay -addr 127.0.0.1:8787
   ```
2. 在 Cloudflare Zero Trust 控制台（Networks → Tunnels）创建 tunnel，按提示在电脑上安装 `cloudflared`，把你的域名（如 `dsh.example.com`）映射到 `http://127.0.0.1:8787`
3. Cloudflare 控制台该域名开启 SSL/TLS（Full 或 Flexible 均可，边缘侧自动 WSS）
4. 插件与 App 的 relay 地址填：`wss://dsh.example.com/ws` —— 完成，无需任何端口映射

> 提示：Caddy 方案的 `--trust-proxy` 同样适用于 Tunnel 后面的真实 IP 解析（Cloudflare 会注入 X-Forwarded-For）。

---

## 姿势 C：Tailscale / 局域网直连（零公网暴露）

适合：个人使用、公司内网，或者你就是不想让任何服务器碰你的数据。

### 局域网直连（最简）

电脑与手机连同一 Wi-Fi：

1. relay 跑在电脑上：`go run -C server ./cmd/relay -addr :8787`（或 Windows 直接跑 `relay.exe`）
2. 电脑防火墙放行 8787 入站（Windows：`netsh advfirewall firewall add rule name="dsh-solo relay" dir=in action=allow protocol=TCP localport=8787`）
3. 插件 relayUrl 与 App 地址都填：`ws://<电脑局域网IP>:8787/ws`

### Tailscale（跨网络也能连，流量端到端走 WireGuard）

```bash
# 电脑与手机都安装 Tailscale 并登录同一账号（免费档够用）
# 电脑上查 Tailscale IP：tailscale ip -4    （形如 100.x.y.z）
# relay 照常跑 127.0.0.1:8787
# 插件与 App 地址填：ws://100.x.y.z:8787/ws
```

Tailscale 模式下**没有任何服务器部署**，适合对隐私要求极高的个人使用；代价是手机离开 Tailscale 网络时不可达。

---

## 插件侧配置

宿主配置文件（cordis.yml / patch）里指向你的 relay：

```yaml
- insert:
    - id: dsh-solo
      name: '<仓库>/packages/agent/dist/dsh-solo-agent.bundle.js'   # 单文件 bundle，无需 npm install
      config:
        relayUrl: 'wss://<你的域名>/ws'      # 姿势 A/B；局域网/Tailscale 用 ws://<IP>:8787/ws
        workspaceRoots:
          - 'd:/your-workspace'
```

`deviceToken` 首次启动自动生成并持久化到 `<workspaceRoots[0]>/.dsh-solo/device-token`；电脑端配对页（`http://127.0.0.1:8790`）扫码即可把地址与令牌一键带到 App。

## 可选：域名备案静态页

域名在中国大陆完成 ICP 备案后，接入商会不定期核验「网站可访问、内容与备案一致」；根路径长期 404/拒绝连接可能被判定为空壳网站。可以让 Caddy 在根路径伺服一个静态页（`/ws`、`/healthz` 转发不受影响，App 无感知）：

1. 创建 `deploy/site/index.html`（该目录已 gitignore：页面含真实备案号，不入库，需自行上传到服务器）。页面标题与备案「服务名称」一致，页脚展示 ICP 备案号并链接 `beian.miit.gov.cn`；公安备案通过后再补公安备案号并链接 `beian.mps.gov.cn`。
2. `docker-compose.yml` 已把 `./site` 挂载到 Caddy 的 `/srv/site`，根路径由 `file_server` 伺服；目录为空时返回 404，与旧行为一致，不需要备案页的自建用户不受影响。
3. 若备案「网站首页」是 www 子域名：给 www 加一条与主域名相同的 DNS A 记录，再创建 `deploy/caddy-extra/www.caddy`（同样已 gitignore）写入 www 站点块。Caddyfile 末尾的 `import /etc/caddy/extra/*.caddy` 会自动加载，空目录不报错。Caddy 自动为 www 申请证书。
4. 不要把主域名重定向到 www：App 的 WebSocket 升级请求经不起 301。

裸机 Caddy（非 Docker）同理：站点目录放 `/srv/dsh-solo-site`，额外站点块放 `/etc/caddy/extra/`，模板见 `deploy/Caddyfile`。

## 常见问题

- **`hello.error` / 连不上**：两端 deviceToken 必须一致；`hello.error` 后客户端停止重连，检查 token 是否配对、是否角色冲突（同一 token 不允许两个 agent）
- **App 提示连接被重置**：公网部署请走 WSS（姿势 A/B），纯 WS 只适合局域网
- **上传失败 "file too large"**：默认单文件 10MB 上限，可在 relay `--max-upload` 调整；上传速率受 `--upload-rate/--upload-burst` 保护
- **证书续期**：Caddy 自动处理，无需 cron；Cloudflare Tunnel 则完全无证书问题

# DSH-SOLO relay 生产部署（WSS + Caddy 反向代理）

> 前置背景：[RELAY_DEPLOY.md](RELAY_DEPLOY.md) 是"无域名、明文 WS 直连"的过渡方案（单人自用可接受）。
> 本手册是公开使用/多人使用的**正式方案**：TLS 加密 + 只暴露 443 + 连接防护。

目标形态：

```
手机/插件 --wss://<域名>/ws--> Caddy(:443, TLS) --ws://127.0.0.1:8787--> relay
```

- TLS 在 Caddy 终结，relay 代码零改动，只监听本机回环
- 公网只开 80/443，8787 不再暴露
- 客户端（App / dsh 插件）只需把 relay 地址从 `ws://IP:8787/ws` 换成 `wss://<域名>/ws`，无需改代码

## 0. 前置

| 事项 | 说明 |
|---|---|
| 域名 | A 记录指向 VPS IP。**境内 VPS 必须备案**（约 2~3 周）；不想备案就换香港/境外同价位 VPS |
| 端口 | 防火墙/安全组放行 80、443（80 供证书签发与跳转） |
| relay 二进制 | 仓库 `server/bin/relay-linux-amd64`（或自行 `GOOS=linux GOARCH=amd64 go build ./cmd/relay`） |

## 1. 防火墙：只留 80/443 与 SSH

```bash
sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw enable
# 如此前对公网开过 8787，务必删除：
sudo ufw delete allow 8787/tcp
```

云控制台的安全组同步：放行 80/443，删除 8787。

## 2. 部署 relay

```bash
sudo mkdir -p /opt/dsh-solo
sudo cp relay-linux-amd64 /opt/dsh-solo/relay
sudo chmod +x /opt/dsh-solo/relay
sudo cp relay.service /etc/systemd/system/
# （可选）编辑 relay.service 给 --bark-url 填上你的 Bark 地址
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-relay
systemctl status dsh-relay --no-pager
```

自检：`curl http://127.0.0.1:8787/healthz` 应返回 `ok`。
此时 8787 只在回环可达，公网不可见。

## 3. 安装并配置 Caddy

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy
```

把 `Caddyfile` 里的 `<你的域名>` 替换后安装：

```bash
sudo cp Caddyfile /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

首次 reload 后 Caddy 自动申请 Let's Encrypt 证书（需域名已解析且 80/443 可达）。

## 4. 验证

```bash
# 1) 证书与反代（公网应返回 ok，且浏览器锁标生效）
curl https://<你的域名>/healthz

# 2) 8787 已不可从公网直连（超时/拒绝即正确）
curl -m 3 http://<VPS公网IP>:8787/healthz   # 应失败

# 3) relay 日志可见 guard 参数
journalctl -u dsh-relay -n 5 --no-pager
```

## 5. 客户端切换

- **电脑端 dsh 插件**：把 relay 地址改为 `wss://<域名>/ws` 后重启 dsh（或重启插件进程），重新打开配对页生成新二维码
- **手机 App**：设置 → 扫码配对，扫新二维码即可自动覆盖 relay 地址与令牌；或手动在设置里改 relay 地址

## 6. 防护参数（relay 启动参数，见 relay.service）

| 参数 | 默认 | 说明 |
|---|---|---|
| `--max-rooms` | 256 | 房间总数上限；超出时自动淘汰空置最久的空闲房间，腾不出则拒绝新 token |
| `--max-conn-per-ip` | 8 | 单 IP 并发连接上限（`--trust-proxy` 后按真实 IP 计） |
| `--max-global-conns` | 512 | 全局并发连接上限 |
| `--msg-rate` / `--msg-burst` | 80 / 160 | 单连接消息令牌桶；超速连接直接断开 |
| `--trust-proxy` | false | **仅在可信反代后开启**，否则 X-Forwarded-For 可被伪造绕过单 IP 限制 |

安全边界：房间数据仍以 deviceToken（128 位熵）隔离；wss 保证链路密文；
令牌泄露可在配对页重置令牌使旧令牌立即失效。

## 7. 备案说明（境内 VPS）

- 使用域名 + 境内服务器对外提供 80/443 服务，必须完成 ICP 备案（腾讯云/阿里云控制台可办，免费，约 2~3 周）
- 备案期间可先用 IP:8787（现状）过渡；备案通过后再切 wss
- 不想备案：换香港/境外 VPS（同价位），域名免备案直用

# dsh-solo Relay VPS 部署手册（Ubuntu · 无域名 · 明文 WS）

> 架构：手机 App 和电脑上的 dsh+agent 都是 WebSocket **客户端**，主动出站连接 VPS 上的 relay。
> 电脑无需开放任何入站端口；手机在任何网络（4G/Wi-Fi）都能连。
>
> **升级路线**：本手册为无域名过渡方案（明文 WS 直连）。公开使用/多人使用前，
> 请按 [README.md](README.md) 升级为 WSS + Caddy 反代（TLS 加密 + 连接防护生效），
> relay 二进制无需重新编译，仅新增 `--trust-proxy` 等参数并改由 Caddy 接入。

## 前置条件

- Ubuntu 服务器一台（已有公网 IP）
- 能 SSH 登录（下文用 `ubuntu` 代指用户名、`VPS_IP` 代指公网 IP，请自行替换）
- 自行构建二进制（仓库根目录）：`GOOS=linux GOARCH=amd64 go -C server build -o ../deploy/relay-linux-amd64 ./cmd/relay`

## 1. 上传二进制到 VPS

在本机 PowerShell 执行：

```powershell
scp d:\traecode-projects\dsh-solo\deploy\relay-linux-amd64 ubuntu@VPS_IP:/tmp/
scp d:\traecode-projects\dsh-solo\deploy\relay.service ubuntu@VPS_IP:/tmp/
```

## 2. VPS 上安装

```bash
# 独立系统用户（不可登录）
sudo useradd -r -s /usr/sbin/nologin dsh || true

# 安装
sudo mkdir -p /opt/dsh-solo
sudo mv /tmp/relay-linux-amd64 /opt/dsh-solo/relay
sudo chmod 755 /opt/dsh-solo/relay
sudo chown -R root:dsh /opt/dsh-solo

sudo mv /tmp/relay.service /etc/systemd/system/relay.service
sudo systemctl daemon-reload
sudo systemctl enable --now relay
```

## 3. 防火墙放行 8787/TCP

```bash
sudo ufw allow 8787/tcp
```

**同时检查云厂商控制台的安全组**（阿里云/腾讯云/AWS 都有），放行 TCP 8787 入站 —— 这步最容易漏。

## 4. 验证

本机任意位置：

```bash
curl http://VPS_IP:8787/healthz
# 输出 ok 即成功
```

看运行日志：

```bash
journalctl -u relay -f
```

## 5. 设备令牌（自动生成，无需手动配置）

令牌不再写死在配置里，由 agent 插件首次启动时自动生成：

- **生成与持久化**：格式为 `dsh-solo-` + 48 位 hex，写入电脑端 `<工作区>/.dsh-solo/device-token`，重启保持不变。
- **查看**：电脑浏览器打开配对页 `http://127.0.0.1:8790`（仅本机可访问；端口占用自动尝试 8791-8799，以启动日志打印的地址为准）。页面展示 relay 地址、令牌（默认打码，点"查看"显示完整）和配对二维码。
- **重置**：配对页点"重置令牌"。重置后令牌立即失效、agent 自动用新令牌重连 relay；手机端需重新扫码或手输新令牌。
- 显式覆盖（不推荐）：在 `cordis.yml` 里写 `deviceToken:` 即回到手动指定模式。

relay 无需任何配置——token 就是房间号，重置后旧 token 的房间自然失效。

## 6. 电脑端（dsh + agent）配置

编辑项目根目录 `cordis.yml`，把 `relayUrl` 改为你的 VPS 地址（`deviceToken` 已删除，自动生成）：

```yaml
config:
  relayUrl: ws://VPS_IP:8787/ws
```

然后重启 dsh web（agent 是插件，随 dsh 重启重连 relay）。本机 PowerShell：

```powershell
# 先结束旧进程（占用 3080 的），再启动
. .\.sdk\env.ps1
node .sdk\dsh\node_modules\@deepseek-ai\dsh\lib\bin.js web --patch d:\traecode-projects\dsh-solo\cordis.yml --no-open
```

启动日志会打印新的网页访问地址（含 token，每次启动会变），以及配对页地址 `pairing page: http://127.0.0.1:8790`。注意 `--patch` 指向项目根目录的 cordis.yml，agent 随之加载并连接 relay。

验证 agent 已接入 VPS relay：VPS 上 `journalctl -u relay -n 20` 应出现 agent 的 hello 日志。

## 7. 手机安装 App（华为 Mate 30 / HarmonyOS 4.2）

HarmonyOS 4.2 兼容 Android APK，可直接安装（仅纯血鸿蒙 HarmonyOS NEXT 不能装 APK）。

APK 位置：`app\build\app\outputs\flutter-apk\app-release.apk`（arm64，Mate 30 麒麟 990 适用；修改 app 代码后需重新执行 `flutter build apk --release` 打包）。

### 7.1 传输 APK 到手机（三选一）

| 方式 | 操作 |
|---|---|
| USB 数据线（推荐） | 手机连电脑，通知栏 USB 用途选"传输文件"，把 APK 复制到手机 `Download` 目录 |
| 微信/QQ 文件传输助手 | 发 APK 给自己，手机端下载。注意：微信下载后可能把后缀改成 `.apk.1`，在文件管理里重命名回 `.apk` 再装 |
| 华为分享 / 网盘 / 蓝牙 | 任意方式，保证文件完整即可 |

### 7.2 安装步骤

1. 手机打开"文件管理" → 进入 `Download` → 点 APK 文件 → 选"安装"
2. 弹出"禁止安装未知来源应用"时，按提示跳转：**设置 → 安全 → 更多安全设置 → 安装外部来源应用**，允许"文件管理"（或你用来下载的应用）
3. 若提示"已受纯净模式限制"：**设置 → 安全 → 更多安全设置 → 纯净模式 → 关闭**（找不到就在设置顶部搜索"纯净模式"），然后重新安装
4. 安装完成，桌面出现 **dsh_solo** 图标，打开进入配置页

### 7.3 adb 安装（可选，免手动拷贝）

手机开启 USB 调试：设置 → 关于手机 → 连点 7 次"版本号" → 返回找到"开发人员选项" → 打开"USB 调试"。插线并在手机上确认调试授权后，本机执行：

```powershell
. .\.sdk\env.ps1
adb install -r d:\traecode-projects\dsh-solo\app\build\app\outputs\flutter-apk\app-release.apk
```

（adb 在 `.sdk\android-sdk\platform-tools`，env.ps1 已将其加入 PATH）

## 8. 手机 App 配置

App 首次启动配置页：服务器地址已预填默认 relay 地址（可通过 `--dart-define=DSH_DEFAULT_RELAY=ws://VPS_IP:8787/ws` 在打包时固化），只需填设备令牌，两种方式：

- **扫码配对（推荐）**：电脑浏览器打开配对页 `http://127.0.0.1:8790`，App 点「扫码配对」扫描二维码，自动填入地址与令牌，回 App 点「连接」即可。
- **手输**：电脑端配对页点「查看」拿到完整令牌，在 App 里手动输入。

保存后 App 重连。验证链路：手机发一条消息 → `journalctl -u relay -f` 里能看到 agent/mobile 的接入与转发。若电脑端重置过令牌，App 会提示鉴权失败，重新扫码即可。

## 9. 安全须知（明文模式）

- `ws://` 流量**不加密**，token 与消息内容公网可见，存在中间人窃听/重放风险。调试期可接受，**长期使用必须升级 TLS**。
- 升级路径：买个域名解析到 VPS → Caddy 反代自动申请 Let's Encrypt 证书 → relay 本身支持 `-tls-cert/-tls-key` 也可直接挂证书 → 三端地址改成 `wss://域名/ws`。
- relay 无本地状态（纯内存转发 + 环形缓冲），重启无副作用。

## 10. 升级 relay 二进制（2026-10-27 新增防护版）

新版 relay 内置连接防护（默认值即生效，无需改任何启动参数）：
房间总数上限 256（满时自动淘汰空置最久的空闲房间）、单 IP 并发连接上限 8、
全局连接上限 512、单连接消息限流 80 条/秒（突发 160），连接日志带来源 IP。

> 注意：仓库里 `deploy/relay.service` 是 **wss + Caddy 部署**用的（监听 127.0.0.1），
> **不要**在明文直连模式下覆盖 VPS 上的旧 service。保持现有 service 不动即可。

### 10.1 上传并替换

本机 PowerShell：

```powershell
scp d:\traecode-projects\dsh-solo\deploy\relay-linux-amd64 ubuntu@VPS_IP:/tmp/
```

VPS 上（`mv` 原子替换，运行中也安全）：

```bash
sudo mv /tmp/relay-linux-amd64 /opt/dsh-solo/relay
sudo chmod 755 /opt/dsh-solo/relay
sudo systemctl restart relay
```

- `systemctl restart relay` 才是重启；`daemon-reload` 只是重新读取 service 文件定义，只在改过 `.service` 文件后需要，本次不用。
- 重启断线几秒，App 与插件自动重连，会话历史不丢（重连后自动补发快照）。

### 10.2 验证升级成功

```bash
journalctl -u relay -n 10 --no-pager
```

看到 guard 参数行即新版已生效：

```
[relay] guard: max-rooms=256 max-conn-per-ip=8 max-global-conns=512 msg-rate=80/s burst=160 trust-proxy=false
```

此后设备接入日志会带来源 IP：`[WS] agent connected (token=dsh-solo-xxx... ip=x.x.x.x)`。

## 11. 常见问题

| 现象 | 排查 |
|---|---|
| healthz 不通 | 云安全组 / ufw / 二进制没跑（`systemctl status relay`） |
| App 连不上但 healthz 通 | token 三端不一致；App 地址少写 `/ws` 路径 |
| agent 连不上 | cordis.yml 改完没重启 dsh；`journalctl -u relay` 里应出现 agent 接入日志 |
| 想换端口 | 改 `relay.service` 的 `-addr :8787`，三端地址同步改 |
| APK 装不上 / 解析失败 | 关闭纯净模式；微信传输后缀被改成 `.apk.1` 需改回；文件传输损坏就重新拷贝 |

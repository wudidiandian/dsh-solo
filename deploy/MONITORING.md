# 中转服务监控：部署接管说明

本版增加单节点只读监控台，不改变 App / 插件的配对协议。管理页面与 `/ws` 分开监听；默认关闭，不会自动对公网开放。开发和验证仅在本机完成，线上部署由维护者接管。

有 Go 环境时，可在项目根目录运行 `npm run pack:relay` 重新生成交付包，输出到 `.generated/dsh-solo-relay-monitor-0.1.0.tar.gz`（文件名随项目版本变化）。其中只包含两个 Linux 架构的二进制、部署说明、无密码配置模板、systemd 覆盖层、构建信息与校验文件，不包含真实服务域名或管理密码。`BUILD.json` 会注明源码提交及工作区是否有未提交修改。

## 可以看到什么

- 在线手机角色连接、电脑插件连接、活跃房间、已配对房间、保留房间。
- 当前连接占用、累计已握手连接、已握手连接峰值，以及配置的连接/房间上限。
- 应用消息收发数量、累计正文流量、近期速率、上传分块正文流量。
- 连接拒绝、消息/上传限流、文件大小拒绝、慢消费者、握手/升级/读写/推送异常。
- 进程 CPU、RSS、Go 堆、Goroutines；Linux 系统可见 CPU、内存和网卡计数；可读取时显示 cgroup 内存和 CPU 配额。
- 每 5 秒采样的连接、流量、CPU 与内存趋势，保留最近一小时。
- 在线终端列表：连接编号、角色、脱敏房间、脱敏 IP、连接时长、最近活动、待发送消息数；支持筛选和分页。

## 指标口径与边界

1. **App 数是连接数，不是独立用户数。** 一个房间可连接多个 App。已配对房间指至少一个电脑插件和一个 App 同时在线。
2. 当前连接占用包含正在握手的连接；角色计数只包含已经完成握手的连接。连接限额现在覆盖完整 WebSocket 生命周期，在连接实际关闭后释放。
3. 消息流量按实际读入/成功写出的 WebSocket 正文长度累计，不含 TLS、帧头等网络开销；广播给三台 App 会计三次发出。上传指标统计 `file.chunk` 信封正文，包含 Base64 和 JSON，不能当作原始文件大小。Ping/Pong 不计入正文流量。
4. 进程 CPU 单核满载为 100%，多核可超过 100%。系统 CPU 来自 `/proc/stat`；容器可能看到宿主机 CPU、内存视图。cgroup 配额单独展示，不把宿主资源误当作容器可用配额。网卡计数可能包含其他程序/容器流量，不等于 relay 流量。
5. 非 Linux 平台仍提供连接、流量、Go 堆等指标，暂不提供 OS CPU/RSS/系统内存/网卡指标，页面显示“—”；Linux 首次 CPU 速率在第二次采样后可用。
6. 所有累计值、趋势与登录会话随进程重启清零；房间脱敏标识也随重启改变。没有数据库、历史留存、告警推送或跨节点汇总。
7. 监控页/API 不返回原始配对令牌、完整 IP、会话 ID、标题或消息。房间用进程随机密钥进行 HMAC 脱敏，不能拿页面编号连接业务服务。现有业务日志的内容与此页面分开管理。
8. 管理端只读，没有断开终端、执行命令、修改限额或自动扩容的操作。高在线数不直接等于需要扩容；结合持续 CPU/内存、流量、错误、队列和独立压测判断。

## 部署前准备

建议先记录当前二进制版本、服务启动参数与防火墙规则，并备份旧二进制。更新 relay 会中断现有长连接，客户端随后重连；内存中的快照与续传缓冲也会清空，安排合适的更新时间。

生成独立管理密码，例如在服务器执行 `openssl rand -base64 32`，将结果填入私有环境文件。不要使用设备配对令牌作为管理密码，也不要将密码放进启动参数、Git 或截图。管理用户名默认 `admin`，密码至少 16 字节。

## 方式 A：现有 systemd / 二进制部署

交付包提供 `relay-linux-amd64` 与 `relay-linux-arm64`，先用 `uname -m` 确认架构（`x86_64` 对应 amd64，`aarch64` 对应 arm64），并在解压目录运行 `sha256sum -c SHA256SUMS`。以下假设现有二进制为 `/opt/dsh-solo/relay`，服务单元名为 `relay.service`；请按真实路径与名称调整。

1. **准备环境文件**，先不要重启现有服务：

   ```sh
   sudo install -d -m 750 /etc/dsh-solo
   sudo cp monitor.env.example /etc/dsh-solo/monitor.env
   sudo chmod 600 /etc/dsh-solo/monitor.env
   sudoedit /etc/dsh-solo/monitor.env
   ```

   保持 `DSH_ADMIN_ADDR=127.0.0.1:8788`，填入随机密码和节点名称。EnvironmentFile 由 systemd 读取，动态服务用户无需直接读取该文件。

2. **添加配置覆盖层**，保留现有业务启动参数：

   ```sh
   sudo install -d /etc/systemd/system/relay.service.d
   sudo cp relay-monitor.conf /etc/systemd/system/relay.service.d/monitor.conf
   sudo systemctl daemon-reload
   ```

3. **备份并替换二进制**（以下以 amd64 为例）：

   ```sh
   sudo cp /opt/dsh-solo/relay /opt/dsh-solo/relay.before-monitor
   sudo install -m 755 relay-linux-amd64 /opt/dsh-solo/relay.next
   sudo systemctl stop relay.service
   sudo mv /opt/dsh-solo/relay.next /opt/dsh-solo/relay
   sudo systemctl start relay.service
   sudo systemctl status relay.service --no-pager
   ```

4. **在服务器上确认**：

   ```sh
   curl -fsS http://127.0.0.1:8787/healthz
   curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8788/api/snapshot
   ```

   业务健康检查应返回 `ok`，未登录的监控 API 应返回 **401**。默认公网 Caddy 路由仍只代理 `/ws` 和 `/healthz`，不需要新增管理页面路由。

## 方式 B：现有 Docker Compose 部署

此方式从完整项目源码构建；二进制交付压缩包不包含全部 Docker 构建上下文。在项目根目录操作：

```sh
cp deploy/monitor.env.example deploy/.env.monitor
chmod 600 deploy/.env.monitor
# 编辑 deploy/.env.monitor，填入管理密码与节点名
docker compose --env-file .generated/deploy.env --env-file deploy/.env.monitor \
  -f deploy/docker-compose.yml -f deploy/docker-compose.monitor.yml config --quiet
docker compose --env-file .generated/deploy.env --env-file deploy/.env.monitor \
  -f deploy/docker-compose.yml -f deploy/docker-compose.monitor.yml up -d --build
```

`.generated/deploy.env` 由统一配置生成，已有部署沿用现有域名配置即可。覆盖文件在容器内监听 `0.0.0.0:8788`，**宿主映射仅为 `127.0.0.1:8788`**。无需向公网开放 8788，也不需要修改 Caddy。

检查容器状态及上述两个本机端点。容器资源字段以运行时可见的 `/proc` 与 cgroup 文件为准，具体部署仍需你在服务器上验收。

## 从自己的电脑访问

保持监控只监听服务器回环地址，通过 SSH 转发访问。在自己的电脑执行并保持该终端运行：

```sh
ssh -N -L 18788:127.0.0.1:8788 <SSH用户名>@<服务器地址>
```

随后在本机浏览器打开 `http://127.0.0.1:18788`，使用环境文件里的管理账号登录。登录有效期 8 小时；退出登录会立即撤销当前会话。每分钟最多允许 5 次登录尝试（该节点共用），超出返回 429，稍后重试。

不要在公网直接使用 HTTP 登录。首版按 SSH 隧道访问设计；若后续改为公网 HTTPS 管理域名，需要单独配置认证边界、代理与 Cookie 策略并验证，不建议直接把管理端口加入当前公网反代。

## 上线验收

- 先验证未登录 API 返回 401，再验证登录、退出与重新登录。
- 用一套电脑插件和 App 配对，核对两种角色、配对房间及连接时长。
- 断开 App，等待正常断开或心跳超时，确认角色计数下降；重连后恢复。
- 进行普通会话和小文件传输，观察流量与错误统计；不在生产服务上做洪水或极限压测。
- 等待至少两次采样，确认 Linux CPU/RSS 数据和趋势；核对容器配额与实际部署是否一致。
- 观察正常使用是否新增连接限额拒绝；本版修复了原先提前释放连接计数的问题，原有限额现在会真实生效。需要更多用户并发时先明确调整连接限额，不要盲目关闭防护。
- 确认 8788 仅监听回环或仅映射回环，公网业务域名不能访问监控接口。

完成上述验收后，再继续用户手动安装回归和 npm 发布。此版本不实现多节点路由/负载均衡，不能把现有房间状态简单分散到不同服务器。

## 回滚

二进制部署：停止服务，恢复 `relay.before-monitor` 为 `relay`，移除或停用仅新增的 `monitor.conf` 覆盖层，执行 `daemon-reload` 后重新启动。原私有环境文件可保留用于下次部署。Docker 部署应事先保存旧镜像标签，回滚至旧镜像，并去掉监控覆盖文件。回滚同样会断开当前连接。

## 本地验收记录（2026-10-31）

- Windows Go 测试、`go vet` 及监控脚本语法检查通过。
- 在现有 Ubuntu 22.04 环境执行 Linux 测试二进制，监控鉴权/会话撤销/限流/历史上限测试、CPU/RSS/系统内存采样测试和中转服务测试全部通过。
- 五个本机模拟终端正确显示为三个 App、两个电脑插件、两个配对房间；浏览器中的筛选、搜索、趋势、暂停刷新与退出登录通过检查，无脚本错误。此数据不是线上使用量。
- 插件 35 项、App 21 项回归测试通过，包含与 Go relay 的跨语言联调。
- Compose 监控覆盖文件的配置解析通过；未在本机启动 Docker 容器，生产 systemd/Docker 的实际权限和网络仍需部署时验收。
- Linux amd64 / arm64 二进制均可构建；arm64 版本未在对应硬件实跑。没有进行生产性能压测，也没有修改线上服务器、发布 npm 或公开仓库。

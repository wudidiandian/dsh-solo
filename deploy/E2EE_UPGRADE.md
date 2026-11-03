# 0.1.5 加密协议升级与回滚

0.1.4 不支持端到端加密，0.1.5 的 App、插件和中转需要配套使用。新中转默认拒绝未加密客户端，新客户端不会静默回退到明文。**先升级中转，再发布/升级客户端并重新扫码**。正式公网地址继续使用 WSS，已有 Caddy、域名和独立监控配置无需变更。

## 1. 备份与确认

从 Releases 下载对应架构的 `relay-linux-amd64` 或 `relay-linux-arm64`，并核对 SHA256SUMS。以下命令针对原有 `/opt/dsh-solo/relay` 和 `relay.service`；使用其他路径/服务名时应相应调整。不要在测试服务目录操作正式服务。

```bash
sudo systemctl cat relay.service
sudo cp /opt/dsh-solo/relay /opt/dsh-solo/relay.before-0.1.5
```

保留 `/etc/dsh-solo/monitor.env`、原 service 与 Caddy 配置的安全备份。不要把监控密码或配对凭据粘贴到公开问题中。

## 2. 迁移窗口

如果仍有用户运行 0.1.4，可以在新中转的原 ExecStart 末尾临时添加 `--allow-legacy`。**这仅允许旧连接继续使用原有明文业务协议，不会给旧客户端补上端到端加密。** 新客户端的加密握手依然必需，不能降级。

旧服务若显式指定 `--msg-rate 80 --msg-burst 160`，同步改为 `--msg-rate 8000 --msg-burst 16000`；显式旧参数会覆盖新默认值。保留原 addr、trust-proxy、连接上限和监控环境文件。

建议使用 `sudo systemctl edit relay.service` 配置 ExecStart 覆盖：先写一行空的 `ExecStart=`，再写完整的新 ExecStart。不要只粘贴额外参数，或误删原有监控 drop-in。

## 3. 替换二进制并验收

以下以 x86_64 为例，在下载文件所在目录执行：

```bash
sudo install -m 755 relay-linux-amd64 /opt/dsh-solo/relay.next
sudo systemctl stop relay.service
sudo mv /opt/dsh-solo/relay.next /opt/dsh-solo/relay
sudo systemctl daemon-reload
sudo systemctl start relay.service
sudo systemctl status relay.service --no-pager
sudo journalctl -u relay.service -n 50 --no-pager -o cat
curl --fail http://127.0.0.1:8787/healthz
```

确认 WSS 反代仍可达、监控正常，并用 0.1.5 插件和正式 App 新扫码验证：锁图标、项目、任务、工具、审批、附件、重连补齐。监控只反映连接及流量，不能读取新加密会话正文。保持旧版兼容窗口时，再验证一个旧客户端仍可用。

完成客户端迁移后删除 `--allow-legacy` 并重启服务，确认旧客户端被拒绝。默认消息限额为每连接 8,000 WebSocket 帧/s、突发 16,000；手机上行密文字节限额仍为 1 MiB/s、突发 4 MiB，不是服务器总/月流量配额。

## 4. 回滚

```bash
sudo systemctl stop relay.service
sudo install -m 755 /opt/dsh-solo/relay.before-0.1.5 /opt/dsh-solo/relay
```

恢复备份的原服务配置（旧二进制不识别 `--allow-legacy`），运行 `sudo systemctl daemon-reload` 后启动服务。回滚到 0.1.4 中转后，客户端也必须回到匹配的 0.1.4；新加密 App/插件不能连接旧中转。保留端侧历史和配对状态目录，但切回旧协议或重置凭据可能要求重新扫码。

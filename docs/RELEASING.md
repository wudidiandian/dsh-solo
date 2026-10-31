# 配置与发布

## 统一配置

复制 `config/distribution.example.json` 为 `config/distribution.local.json`，修改字段，再运行 `npm run configure`：

| 字段 | 用途 |
| --- | --- |
| `relayUrl` | 插件和 App 的默认 WebSocket 地址，公网用 `wss://你的域名/ws` |
| `legacyRelayUrl` | 可选，需要从旧地址迁移的 App 配置；留空则不迁移 |
| `relayDomain` | 服务端 Caddy 使用的域名，无协议和路径 |

私有配置和生成文件均已忽略。可通过 `DSH_CONFIG_FILE` 指定其他配置文件；显式指定的文件不存在会报错。没有本地配置时使用公开示例，本机默认地址仅供开发。

- 插件：`npm run build` 或 `npm run bundle --workspace=dsh-solo-agent` 自动生成默认配置。宿主显式传入的 `relayUrl` 优先。
- App：先运行 `npm run configure`，再在 `app` 目录执行 `flutter build apk --release --dart-define-from-file=../.generated/flutter-defines.json`。保存的地址和扫码地址优先于构建默认值。
- 服务端：根目录执行 `docker compose --env-file .generated/deploy.env -f deploy/docker-compose.yml up -d --build`。域名由 Caddy 使用，Go relay 本身无需知道公网域名。

切换配置后重新构建需要分发的各端。不要提交生成文件或私有配置。配置注入避免公开源码写死官方地址，但安装包和网络流量仍可揭示服务器地址；不能将域名视为访问凭证。

## Android 签名

正式 APK 不再使用 debug key。构建时设置：

- `ANDROID_KEYSTORE_PATH`：签名密钥文件的绝对路径。
- `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`：相应签名参数。

备份并长期复用同一把发布密钥。此前使用 debug key 安装的 App 无法直接升级为新签名，可能需要卸载重装，注意保留配对信息。

## GitHub 工作流

日常 push 与 PR 检查 TS / Go / Flutter，不自动发布 APK。推送 `v*` 标签会构建插件和签名 APK，生成含 SHA256 校验文件的 **Release 草稿**。检查草稿后再发布。服务端由维护者部署，不作为普通用户下载项。

首次运行前创建 GitHub `release` Environment，配置 Secrets：

- `DISTRIBUTION_CONFIG`：完整私有配置 JSON，字段同示例。
- `ANDROID_KEYSTORE_BASE64`：发布密钥文件的 Base64 内容。
- `ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。

发布前同步根目录、插件和 App 的版本；App 的 `pubspec.yaml` 中 `+` 后构建号必须递增。当前工作流不自动修改版本，不发布 npm，也不会自动上线服务器。Flutter SDK 版本必须与 `app/pubspec.yaml` 和 Android 构建工具兼容。

## 首次公开前

开发交接和设计笔记已移到本地忽略目录 `private-docs/`。忽略文件不会清除 Git 历史：旧提交中仍可能包含域名、IP、配对凭证或运营内容。公开现有仓库前需审查整个历史；也可以从审核后的当前文件创建全新公开仓库，保留旧仓库为私有。不要直接推送现有历史后才删除文件。

公开仓库从审核后的源码建立独立历史；旧开发记录保存在私有历史仓库中。官方安装包需由维护者配置签名和 Secrets 后发布。

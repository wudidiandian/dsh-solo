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

官方云服务公开推广前，建议先按 [监控部署接管说明](../deploy/MONITORING.md) 完成服务器更新和验收，再执行用户手动安装回归，最后发布 npm 与准备公开仓库。监控部署由维护者接管，不由插件安装或 npm 发布自动触发。

日常 push 与 PR 运行检查，不自动发布安装包。发布使用 `.github/workflows/release.yml` 的 **Release packages → Run workflow**，不需要手动创建或推送 tag。

### 首次配置

将工作流和相关脚本提交并推送到运行仓库的默认分支，创建 GitHub `release` Environment，并配置以下 Secrets：

| Secret | 内容 |
| --- | --- |
| `DISTRIBUTION_CONFIG` | 完整私有配置 JSON，字段同示例 |
| `ANDROID_KEYSTORE_BASE64` | 正式 Android 签名密钥文件的 Base64 内容 |
| `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| `ANDROID_KEY_ALIAS` | 签名别名 |
| `ANDROID_KEY_PASSWORD` | 签名密钥密码 |

安装包与版本 tag 发布到工作流所在的**当前源码仓库**：[wudidiandian/dsh-solo Releases](https://github.com/wudidiandian/dsh-solo/releases)。工作流使用 `github.repository` 确定目标，使用 GitHub 内置 `GITHUB_TOKEN`，并已为发布任务声明 `contents: write` 权限。无需额外创建发布令牌，也无需配置 `RELEASE_REPOSITORY` 变量；历史的同名变量不会影响当前工作流。

2026-11-01 核查：运行仓库 `dsh-solo` 的 `release` Environment 已配置 `DISTRIBUTION_CONFIG`；正式签名的四项 Secrets 仍需维护者补齐。缺配置时工作流会在构建前失败并列出缺项。

### 每次发布

1. 同步根目录 `package.json`、`packages/agent/package.json` 和 `app/pubspec.yaml` 的正式版本，并更新 lockfile。例如下一版统一为 `0.1.5`，App 使用 `0.1.5+6`；App 的构建号需递增。
2. 提交并推送所有要发布的改动。进入运行仓库 **Actions → Release packages → Run workflow**，选择包含这些改动的分支。版本输入可留空，自动读取已提交的版本；填写时必须与源码版本一致。
3. 工作流检查配置和版本，运行 TS / Go / Flutter 测试，构建官方插件与 **正式签名的 release APK**。
4. 在当前源码仓库自动创建 `v<版本号>` tag，指向本次实际构建的源码提交，并将安装包发布到同一仓库的 Releases。
5. 上传下列文件，检查上传文件名和大小后发布正式 Release，并设为 `latest`：
   - `dsh-solo-agent-<版本号>.tgz`
   - `dsh-solo.apk`
   - `BUILD.json`（版本、App 构建号和源码提交）
   - `SHA256SUMS`（文件校验值）

上传过程先创建草稿；上传失败时不会公开不完整的 Release。同一源码的未完成草稿可重跑，已公开的 Release 和指向其他提交的同名 tag 不覆盖，应提升版本后再发布。tag 推送不触发本发布工作流，避免重复发布。

最新版 App 固定下载链接：

[下载 Android APK](https://github.com/wudidiandian/dsh-solo/releases/latest/download/dsh-solo.apk)

此链接在首次正式 Release 发布后可用；目标仓库保持私有时，下载者需要相应 GitHub 权限。工作流不改变仓库可见性。

当前工作流不自动修改源码版本，不发布 npm，也不会自动上线服务器。npm 的 `latest` 与 GitHub 的最新 Release 分别维护；同版 npm 已发布时无需重复发布。Flutter SDK 版本必须与 `app/pubspec.yaml` 和 Android 构建工具兼容。

插件可先在本机运行 `npm run pack:plugin`，构建标准 DSH bundle，并在开发仓库外检查打包入口能否独立加载。`.tgz` 解压后的 `package` 目录可通过桌面版“添加插件”安装。不要将单个 JavaScript 文件当作完整的桌面安装包。npm 发布与第三方市场收录分别处理，见 [插件安装与市场分发](PLUGIN_INSTALLATION.md)。

## 首次公开前

开发交接和设计笔记已移到本地忽略目录 `private-docs/`。忽略文件不会清除 Git 历史：旧提交中仍可能包含域名、IP、配对凭证或运营内容。公开现有仓库前需审查整个历史；也可以从审核后的当前文件创建全新公开仓库，保留旧仓库为私有。不要直接推送现有历史后才删除文件。

公开仓库从审核后的源码建立独立历史；旧开发记录保存在私有历史仓库中。官方安装包需由维护者配置签名和 Secrets 后发布。


## npm 测试版

本次测试版本为 `dsh-solo-agent@0.1.4-beta.1`，以 `beta` 标签发布到公共 npm registry。GitHub 可继续保持 private；npm 包自身公开可下载。先运行 `npm test` 和 `npm run pack:plugin`，再发布已经检查过的归档：

```sh
npm publish .generated/dsh-solo-agent-0.1.4-beta.1.tgz --tag beta --access public --registry=https://registry.npmjs.org/
npm view dsh-solo-agent@beta version dist.integrity --registry=https://registry.npmjs.org/
```

桌面版输入 `dsh-solo-agent@beta`，或固定 `dsh-solo-agent@0.1.4-beta.1`；首次发布时优先使用官方 npm 源，镜像同步有延迟。用户完成网页登录及 npm 要求的发布验证后才能发布；准备好归档不代表发布完成。

App 界面关闭 DEBUG 角标，但这不会把 debug APK 转为 release APK。正式 Android 仍执行上面的 `--release` 构建并使用维护者配置的发布签名；不以关闭角标代替正式构建。


## 正式版 0.1.4

正式插件使用版本 `0.1.4`，发布配置中的标签为 `latest`。运行 `npm test`、`npm run pack:plugin` 及安装包检查后，发布经过检查的归档：

```sh
npm publish .generated/dsh-solo-agent-0.1.4.tgz --tag latest --access public --registry=https://registry.npmjs.org/
npm view dsh-solo-agent@latest version dist.integrity --registry=https://registry.npmjs.org/
```

不带 `@版本` 的首次安装解析 `latest` 标签；`@beta` 使用独立测试标签；`@0.1.4` 固定版本。已经安装的版本不会仅因标签变化自动升级，需要执行宿主提供的更新/重新安装操作。发布 npm 不会改变 GitHub 仓库可见性。

# DSH-SOLO

**中文** | [English](README_EN.md)

通过手机远程使用电脑上的 DeepSeek Harness：查看会话、发送任务、切换模型、传递附件，并审批需要确认的操作。

## 安装与使用

普通用户只需要安装电脑端插件和 Android App，无需部署服务器。

1. 在 [Releases](https://github.com/wudidiandian/dsh-solo/releases) 下载同一版本的插件与 APK。
2. 在 DeepSeek Harness 中安装插件；发布包提供单文件 `dsh-solo-agent.bundle.js` 和 npm 安装包 `.tgz`，按宿主支持的方式加载。
3. 启动插件，打开启动日志中显示的本机配对页。
4. 安装 APK，在 App 中扫描配对二维码，然后连接。

官方安装包使用随包配置的服务地址。电脑端需要保持运行并能访问中转服务。二维码包含设备配对凭证，请勿公开分享。Android 为当前交付目标；其他平台需要自行适配和验证。

## 功能

- 查看会话和实时回复，重连后同步事件。
- 创建任务、选择模型、重命名和删除会话。
- 在手机上允许或拒绝远程审批。
- 上传图片与文件、选择电脑工作区文件、发送文档链接。
- 查看 Markdown 回复与代码差异。

## 自建与源码构建

源码构建默认连接本机，不包含官方服务器地址。手机自建使用时，请通过电脑端配对二维码获取手机可访问的地址。

环境：Node.js 22、Go 1.22 或更高版本；App 使用 Flutter 3.47.7 / Dart 3.13.5，Android 使用 JDK 17。构建工具版本以工程文件为准。

```sh
npm ci
npm run configure
npm run build
npm run bundle --workspace=dsh-solo-agent
npm test
npm run test:go
```

- [统一配置与发布说明](docs/RELEASING.md)：三端配置、签名、GitHub 自动构建。
- [自建部署](deploy/SELF_HOST.md)：Docker、局域网和隧道接入。
- [协议定义](packages/protocol/src/index.ts)：开发与集成参考。
- [贡献指南](CONTRIBUTING.md)。

本机运行中转服务：`npm run relay`。插件的 `relayUrl` 可以覆盖构建默认值；手机扫码获取地址和令牌，两端使用相同令牌配对。

## 功能路线图

以下是计划中的功能方向，尚未发布；优先级会根据使用反馈和开发进展调整，具体可用功能以 Release 说明为准。

- [ ] **iOS App**：适配 iPhone，打通构建、签名与 TestFlight 测试分发。
- [ ] **鸿蒙端 App**：完成鸿蒙平台适配、HAP 构建与真机验证。
- [ ] **系统通知与离线推送**：在任务完成或需要审批时，通过手机系统通知及时提醒。
- [ ] **语音输入任务**：将语音转为任务文本，方便在手机上发送指令。
- [ ] **多工作站管理**：在手机上切换和管理多台电脑的会话与任务。

欢迎通过 [Issues](https://github.com/wudidiandian/dsh-solo/issues) 反馈需求和使用场景。

## 项目结构

| 目录 | 内容 |
| --- | --- |
| `packages/agent` | 电脑端 Cordis 插件 |
| `packages/protocol` | 通信协议 |
| `app` | Flutter 移动端 |
| `server` | Go 中转服务 |
| `deploy` | 自建部署配置 |

通信方式：手机 App ↔ WebSocket 中转服务 ↔ 电脑端插件。公网部署请使用 WSS。

## 许可证

[MIT](LICENSE)

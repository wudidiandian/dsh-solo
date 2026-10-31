# 贡献指南（Contributing to DSH-SOLO）

感谢关注 DSH-SOLO！客户端、插件与自建服务端采用 MIT 许可，欢迎贡献。

## 开发环境

| 组件 | 版本 |
|---|---|
| Node.js | ≥ 18 |
| Go | ≥ 1.22 |
| Flutter | 3.47.x stable |
| JDK | 17（Android 构建） |

```powershell
# TS 侧（根目录）
npm install && npm run build && npm test

# Go relay
go -C server test ./... -count=1

# Flutter App
cd app && flutter pub get && flutter test
```

> 国内网络：GOPROXY / pub / Gradle 镜像建议配置为 `goproxy.cn` / `pub.flutter-io.cn` / 腾讯 Gradle 镜像。

## 提交规范

- commit message 遵循 Conventional Commits：`feat:` / `fix:` / `docs:` / `refactor:` / `test:` / `chore:`
- 一类改动一个 commit；测试与实现同步提交
- 涉及协议改动（`packages/protocol`）必须同步更新 `schema.json`，并保证 Go / Dart 两侧测试全绿

## 代码约定

- **协议改动是跨端契约**：`packages/protocol/src/index.ts` 改完后必须 `npm run build`，并同步更新 `schema.json`、Go `internal/proto` 与 Dart `lib/protocol/envelope.dart`，三端字段 camelCase 完全一致
- relay 所有新能力必须有 Go 测试（参考 `server/internal/hub/upload_test.go` 的写法）
- agent 新增宿主 API 调用必须"特性探测 + 优雅降级"，不允许硬性依赖宿主版本
- 不提交任何凭证：`deviceToken`、`cordis.yml`、`.dsh-solo/`、`.dsh-home/` 均已 gitignore，新增敏感文件请先补 ignore 规则

## 分支与 PR

1. 从 `main` 拉出 feature 分支（`feat/xxx` / `fix/xxx`）
2. 提交前确保三端测试全绿
3. PR 描述写清：动机、改动点、验证方式；UI 改动附截图

## 报告 Bug

提交 issue 时请附上：

- 平台信息（App 版本 / 电脑端宿主版本 / relay 部署方式：官方云·自建·内网）
- 复现步骤与预期/实际行为
- agent 端 console 日志与 relay 日志片段（**注意抹掉 deviceToken 与 IP**）

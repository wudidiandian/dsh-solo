# DSH-SOLO

[中文](README.md) | **English**

Use DeepSeek Harness on your computer from an Android phone: follow sessions, send tasks, select models, transfer attachments and respond to approvals.

## Install

1. Download the plugin and APK from the same [Release](https://github.com/wudidiandian/dsh-solo/releases).
2. Load `dsh-solo-agent.bundle.js` or the npm `.tgz` package using the installation method supported by your host.
3. Start the plugin and open the local pairing page shown in its logs.
4. Install the APK, scan the pairing QR code and connect.

Official packages contain the service configuration. End users do not need to deploy a server. Keep your computer running and do not share pairing credentials. Android is the current distribution target; other platforms require additional validation.

## Build and self-host

Requirements: Node.js 22, Go 1.22+, Flutter 3.47.7 / Dart 3.13.5 and JDK 17 for Android. Public source builds default to localhost and contain no official server address.

```sh
npm ci
npm run configure
npm run build
npm run bundle --workspace=dsh-solo-agent
npm test
npm run test:go
```

- [Configuration and releases](docs/RELEASING.md)
- [Self-hosting](deploy/SELF_HOST.md)
- [Protocol](packages/protocol/src/index.ts)
- [Contributing](CONTRIBUTING.md)

Run the local relay with `npm run relay`. Override the plugin's `relayUrl` for your deployment and scan its QR code on the phone. Both clients pair using the same device token. Use WSS for public deployments.

## Roadmap

These features are planned and have not been released. Priorities may change based on feedback and development progress; see release notes for available functionality.

- [ ] **iOS app**: iPhone support, build and signing setup, and TestFlight distribution.
- [ ] **HarmonyOS app**: platform adaptation, HAP builds and device testing.
- [ ] **System notifications and offline push**: notify users when tasks finish or need approval.
- [ ] **Voice input**: turn speech into task text for sending instructions from a phone.
- [ ] **Multiple workstations**: switch between and manage sessions and tasks on multiple computers.

Share feature requests and use cases through [Issues](https://github.com/wudidiandian/dsh-solo/issues).

## Repository

`packages/agent`: desktop plugin; `packages/protocol`: protocol; `app`: Flutter client; `server`: Go relay; `deploy`: deployment templates.

## License

[MIT](LICENSE)

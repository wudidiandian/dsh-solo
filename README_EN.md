# DSH-SOLO

[中文](README.md) | **English**

Use DeepSeek Harness on your computer from an Android phone: follow sessions, send tasks, select models, transfer attachments and respond to approvals.

## Install

**The official DSH-SOLO plugin comes preconfigured for the official cloud relay service. Install the plugin and Android app, then scan to pair; no server deployment or server domain entry is required.**

### 1. Install the desktop plugin (recommended)

In the **official DeepSeek Harness desktop app**, open **Plugins → Add plugin**, enter the package name below and select **Install**:

```text
dsh-solo-agent
```

Select **Enable now**. If **Phone pairing** does not appear in the sidebar, fully quit the desktop app through its application menu and reopen it; closing the window may only hide it to the tray.

Without a version suffix, installation uses npm's `latest` stable tag. To pin a version, enter `dsh-solo-agent@0.1.4`. If the package cannot be found, switch to the **official npm registry** while mirrors catch up. Existing installations need an update or reinstall as prompted by the host; pairing data in your home directory's `.dsh-solo` can normally be retained.

### 2. Download the Android app

- **[Download the latest Android APK](https://github.com/wudidiandian/dsh-solo/releases/latest/download/dsh-solo.apk)**
- [All releases, version notes and plugin packages](https://github.com/wudidiandian/dsh-solo/releases)

Install `dsh-solo.apk` on your Android phone. Check release notes for compatible versions. Packages become available after the corresponding Release is published; the latest-download link will work after the first release. Packages are published in this project repository’s Releases. Access and downloads require GitHub repository permissions while the repository is private.

### 3. Pair your phone

1. Select **Phone pairing** in the desktop sidebar or plugin detail page.
2. Tap **Scan to pair** in the phone app, scan the embedded QR code and connect. The address and token are filled automatically.
3. For manual pairing, reveal the token on the desktop pairing page and enter it in the app. The official app already contains the official relay address.

Keep DeepSeek Harness and the plugin running, with both devices online. Do not share pairing credentials. Android is the current distribution target; other platforms require additional validation.

### Alternative: install a plugin archive

For offline installation or a specific archive, download `dsh-solo-agent-<version>.tgz` from [Releases](https://github.com/wudidiandian/dsh-solo/releases).

1. Extract it into a folder you intend to keep. Some tools require extracting the intermediate `.tar` as well.
2. Find the **`package` directory containing `package.json`**, such as `D:/DSH-SOLO/plugin/package`.
3. In the **official DeepSeek Harness desktop app → Plugins → Add plugin**, enter that directory's absolute path, install and enable it.

Select the directory rather than a JavaScript file or an unextracted archive. Keep the directory in place after installation. Uninstall an existing plugin with the same name first and restart as prompted.

Discovery in the third-party `dsh-market` requires separate catalog inclusion; npm publication or a public GitHub repository does not automatically list the plugin.

## Current security and privacy

The current version **does not implement end-to-end encryption between the phone app and desktop plugin**. WSS protects transport to the relay entry point with TLS; the relay can still read forwarded messages, tasks and attachments, and buffers snapshots and some events in memory for reconnection. Plain WS in self-hosted deployments does not provide this transport encryption.

Devices pair using a randomly generated token. Treat it as an access credential and keep both the token and QR code private. The monitoring page shows connection and resource statistics rather than conversation bodies, which does not prevent the server from accessing those bodies. End-to-end encryption is the highest-priority planned feature below, not a capability of the current version.

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
- [Desktop installation and marketplace distribution](docs/PLUGIN_INSTALLATION.md)
- [Self-hosting](deploy/SELF_HOST.md)
- [Relay monitoring and deployment handoff](deploy/MONITORING.md)
- [Protocol](packages/protocol/src/index.ts)
- [Contributing](CONTRIBUTING.md)

Run the local relay with `npm run relay`. Override the plugin's `relayUrl` for your deployment and scan its QR code on the phone. Both clients pair using the same device token. Use WSS for public deployments.

## Roadmap

These features are planned and have not been released. Priorities may change based on feedback and development progress; see release notes for available functionality.

- [ ] **App ↔ desktop plugin end-to-end encryption (highest priority, before iOS)**: verify device identities through QR pairing and establish endpoint keys independent of the relay pairing token. Encrypt conversation bodies, tasks, approvals and attachments so the relay forwards and buffers ciphertext. Include secure key storage, integrity and replay protection, reconnection, multiple devices and protocol compatibility without silently falling back to plaintext. Metadata such as IP addresses, timing and traffic sizes may remain visible to the relay; the desktop and its configured model services still process task content.
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


### Create a session in a desktop project

With plugin and App version `0.1.2` or newer, select **+ → Select project** and choose an available workspace registered on the desktop. The first message creates a session in that project. Existing sessions are kept. The picker requests project names and IDs on demand without scanning project files; the relay needs no update.


### App settings

The home screen gear opens Device connection, Help, Privacy and permissions, and About DSH-SOLO. Pairing still supports QR codes and manual tokens. Help can copy a limited connection report without tokens, server addresses or chat content. About shows the installed version and open-source licenses. These settings are available in App `0.1.3`; the plugin and server need no update.


Stable version `0.1.4` includes embedded QR pairing over the authenticated owner-only Host connection. Desktop and browser clients render it directly. Same-computer users retain a browser backup link. No relay upgrade is needed.


App `0.1.4` adds links to the [GitHub project](https://github.com/wudidiandian/dsh-solo) and author [wudidiandian](https://github.com/wudidiandian) under About.

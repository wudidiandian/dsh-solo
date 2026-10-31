import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_l10n.dart';
import '../relay/relay_client.dart';
import '../state/app_state.dart';

String _t(String zh, String en) => AppL10n.i.isEn ? en : zh;

String _connectionLabel(AppState state) {
  if (state.isDesktopConnected) return AppL10n.i.statusOpen;
  return switch (state.relayStatus) {
    RelayStatus.open when state.checkingDesktop =>
      AppL10n.i.statusCheckingDesktop,
    RelayStatus.open => AppL10n.i.statusDesktopOffline,
    RelayStatus.connecting => AppL10n.i.statusConnecting,
    RelayStatus.fatal => AppL10n.i.statusAuthFailed,
    RelayStatus.closed => AppL10n.i.statusDisconnected,
    RelayStatus.idle => AppL10n.i.statusIdle,
  };
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.state,
    required this.onConfigureConnection,
  });
  final AppState state;
  final Future<void> Function() onConfigureConnection;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final Future<PackageInfo?> _package;
  @override
  void initState() {
    super.initState();
    _package = PackageInfo.fromPlatform()
        .then<PackageInfo?>((info) => info)
        .catchError((_) => null);
  }

  void _open(String title, List<Widget> content) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(padding: const EdgeInsets.all(20), children: content),
        ),
      ),
    );
  }

  Widget _section(String title, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(text),
      ],
    ),
  );

  Future<void> _copyDiagnostics() async {
    final info = await _package;
    // Keep this an explicit allowlist. Never copy token, URL, errors, paths or messages.
    final text = [
      'DSH-SOLO',
      'App: ${info?.version ?? "unknown"} (${info?.buildNumber ?? "unknown"})',
      'Platform: ${kIsWeb ? "web" : defaultTargetPlatform.name}',
      'Build: ${kReleaseMode
          ? "release"
          : kProfileMode
          ? "profile"
          : "debug"}',
      'Relay: ${widget.state.relayStatus.name}',
      'Desktop: ${widget.state.isDesktopConnected ? "online" : "unconfirmed"}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(
              '已复制诊断信息，不含令牌、服务器地址或聊天内容',
              'Diagnostics copied without tokens, server addresses or chat content',
            ),
          ),
        ),
      );
    }
  }

  void _help() => _open(_t('使用帮助', 'Help'), [
    _section(
      _t('安装与配对', 'Install and pair'),
      _t(
        '在 DeepSeek Harness 桌面版安装并启用 dsh-solo-agent。打开“手机配对”中的二维码页面，在本 App 的“设备连接”中扫码，或手动填写设备令牌。电脑和桌面插件需要保持运行。',
        'Install and enable dsh-solo-agent in DeepSeek Harness. Open its Phone pairing QR page, then scan it under Device connection or enter the device token. Keep the desktop app and plugin running.',
      ),
    ),
    _section(
      _t('项目与会话', 'Projects and sessions'),
      _t(
        '新会话点击“＋ → 选择项目”，发送第一条消息后会在所选电脑项目中创建会话。在已有会话中选择项目会开始新会话，原会话保留。',
        'For a new session, select + → Select project. The first message creates the session in that desktop project. Selecting a project in an existing session starts a new session and keeps the original.',
      ),
    ),
    _section(
      _t('无法连接或工具不可用', 'Connection or tool problems'),
      _t(
        '核对设备令牌，确认电脑插件在线；连上转发服务器并不代表已连上电脑。更新插件后完全退出并重启桌面版。工具跟随电脑端默认 Agent 预设；旧版创建的缺工具会话可另建一条会话测试。',
        'Check the device token and desktop plugin. A relay connection alone does not confirm the desktop is online. Fully quit and restart the desktop after updating the plugin. Tools follow its default Agent preset; test a new session if an older session has missing tools.',
      ),
    ),
    _section(
      _t('反馈问题', 'Reporting a problem'),
      _t(
        '记录复现步骤、发生时间、App 与插件版本及错误提示，向提供安装包的维护者反馈。诊断信息仅在点击下方按钮时复制，不会自动发送。请勿分享配对令牌、二维码或未经检查的聊天截图。',
        'Report reproduction steps, time, app/plugin versions and the error to the maintainer who provided the app. The button below only copies diagnostics; nothing is sent automatically. Do not share pairing tokens, QR codes or unchecked chat screenshots.',
      ),
    ),
    FilledButton.icon(
      onPressed: _copyDiagnostics,
      icon: const Icon(Icons.copy_outlined),
      label: Text(_t('复制连接诊断', 'Copy connection diagnostics')),
    ),
  ]);

  void _privacy() => _open(_t('隐私与权限', 'Privacy and permissions'), [
    _section(
      _t('数据经过哪里', 'Where data travels'),
      _t(
        '手机通过中转服务连接电脑插件。中转服务会处理连接 IP、设备令牌、会话消息及手机上传的附件。会话快照和部分事件可在服务端内存中暂存，用于重连恢复。任务内容由电脑端及其配置的模型服务处理。',
        'The app connects to the desktop through a relay. The relay processes connection IPs, device tokens, session messages and attachments uploaded from the phone. Snapshots and some events can be buffered in server memory for reconnection. The desktop and its configured model services process task content.',
      ),
    ),
    _section(
      _t('项目选择与附件', 'Projects and attachments'),
      _t(
        '选择项目只请求电脑已有项目的名称和标识，不扫描或上传整个项目文件夹。手机选择照片或拍照发送时，所选图片会经过中转服务传到电脑；工具结果或回复中出现的文件内容也可能经过中转。',
        'Project selection requests registered project names and IDs without scanning or uploading entire project folders. Photos selected or taken for sending travel through the relay to the desktop. File content included in tool results or replies may also pass through the relay.',
      ),
    ),
    _section(
      _t('传输与本机保存', 'Transport and local storage'),
      _t(
        'WSS 可加密客户端到服务器的传输链路，自建 WS 连接不提供该链路加密。目前尚未实现手机与电脑之间的端到端加密，中转服务能够读取转发内容。本机会保存配对配置、模型选择和部分会话缓存，请妥善保管设备及配对令牌。',
        'WSS encrypts transport to the server; self-hosted WS connections do not provide this transport encryption. Phone-to-desktop end-to-end encryption is not implemented, so the relay can read forwarded content. Pairing settings, model selection and some session history are stored locally. Protect your device and pairing token.',
      ),
    ),
    _section(
      _t('相机与照片', 'Camera and photos'),
      _t(
        '扫码配对与拍照使用相机；选择照片通过系统选择器获取你选中的图片。相关操作由你主动触发，可在系统的应用权限设置中管理。普通文字会话不需要使用相机。',
        'QR pairing and taking photos use the camera. Photo selection uses the system picker to access your selected images. You initiate these actions and can manage permissions in system app settings. Text conversations do not need camera access.',
      ),
    ),
  ]);

  Future<void> _openGitHub(String address) async {
    try {
      if (await launchUrl(
        Uri.parse(address),
        mode: LaunchMode.externalApplication,
      ))
        return;
    } catch (_) {
      // The visible address can still be selected and copied if opening fails.
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _t(
              '无法打开浏览器，可复制页面上的地址访问',
              'Could not open a browser. Copy the address shown on this page instead.',
            ),
          ),
        ),
      );
    }
  }

  Widget _gitHubLink(String label, String value, String address) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: SelectableText(value),
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new),
        tooltip: _t('打开链接', 'Open link'),
        onPressed: () => _openGitHub(address),
      ),
      onTap: () => _openGitHub(address),
    ),
  );

  void _about() => _open(_t('关于 DSH-SOLO', 'About DSH-SOLO'), [
    _section(
      'DSH-SOLO',
      _t(
        '通过手机远程使用电脑上的 DeepSeek Harness。',
        'Use DeepSeek Harness on your desktop from your phone.',
      ),
    ),
    _gitHubLink(
      _t('项目源码（GitHub）', 'Project source (GitHub)'),
      'https://github.com/wudidiandian/dsh-solo',
      'https://github.com/wudidiandian/dsh-solo',
    ),
    _gitHubLink(
      _t('作者', 'Author'),
      'wudidiandian',
      'https://github.com/wudidiandian',
    ),
    FutureBuilder<PackageInfo?>(
      future: _package,
      builder: (context, snapshot) => _section(
        _t('App 版本', 'App version'),
        snapshot.data == null
            ? _t('版本信息暂不可用', 'Version unavailable')
            : '${snapshot.data!.version} (${snapshot.data!.buildNumber})',
      ),
    ),
    _section(_t('电脑端插件', 'Desktop plugin'), 'dsh-solo-agent'),
    _section(
      _t('获取更新', 'Getting updates'),
      _t(
        'App 更新请从维护者提供的发布渠道获取。目前不提供应用内自动更新。电脑端插件请通过 DeepSeek Harness 插件管理器更新。',
        'Get app updates from the maintainer’s release channel. In-app automatic updates are not available. Update the desktop plugin through the DeepSeek Harness plugin manager.',
      ),
    ),
    _section(
      _t('开源许可', 'Open-source license'),
      _t(
        'DSH-SOLO 使用 MIT 许可证。第三方组件的许可证可在下方查看。',
        'DSH-SOLO is licensed under MIT. View third-party component licenses below.',
      ),
    ),
    OutlinedButton(
      onPressed: () =>
          showLicensePage(context: context, applicationName: 'DSH-SOLO'),
      child: Text(_t('开源软件许可', 'Open-source licenses')),
    ),
  ]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: Text(_t('设置', 'Settings'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            _t('连接与支持', 'Connection and support'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.devices_outlined),
                  title: Text(_t('设备连接', 'Device connection')),
                  subtitle: Text(_connectionLabel(widget.state)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onConfigureConnection,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.help_outline),
                  title: Text(_t('使用帮助', 'Help')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _help,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _t('应用信息', 'App information'),
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: Text(_t('隐私与权限', 'Privacy and permissions')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _privacy,
                ),
                const Divider(height: 1, indent: 56),
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(_t('关于 DSH-SOLO', 'About DSH-SOLO')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _about,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

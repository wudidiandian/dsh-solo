/// 主页：连接设置 + 电脑快照（模型列表 + 会话列表 + 目录树）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../config/defaults.dart';
import '../l10n/app_l10n.dart';
import '../relay/relay_client.dart';
import '../state/app_state.dart';
import 'dir_browser_page.dart';
import 'pair_scan_page.dart';
import 'session_page.dart';
import 'settings_page.dart';

/// 主页
class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state, this.initialConfig});

  final AppState state;
  final AppConfig? initialConfig;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;

  @override
  void initState() {
    super.initState();
    // 预填顺序：已保存配置 > 内置默认 relay 地址；令牌由扫码或手输填入
    _urlCtrl = TextEditingController(text: widget.initialConfig?.relayUrl ?? defaultRelayUrl);
    _tokenCtrl = TextEditingController(text: widget.initialConfig?.deviceToken ?? '');
    // 恢复上次选中的模型；之后每次切换都立即持久化（best-effort）
    final savedModelId = widget.initialConfig?.modelId;
    if (savedModelId != null && savedModelId.isNotEmpty) {
      widget.state.selectedModelId = savedModelId;
    }
    widget.state.onSelectedModelChanged = (id) async {
      try {
        final c = await AppConfig.load();
        if (c == null) return;
        c.modelId = id;
        await c.save();
      } catch (_) {
        // 持久化失败不影响使用
      }
    };
    // 已保存过配置则自动连接
    if (widget.initialConfig != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (url.isEmpty || token.isEmpty) return;
    widget.state.connect(RelayClient(url: url, deviceToken: token));
    await AppConfig(
      relayUrl: url,
      deviceToken: token,
      modelId: widget.state.selectedModelId,
    ).save();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SettingsPage(
      state: widget.state, onConfigureConnection: _openConnectionSettings,
    )));
  }

  Future<void> _openConnectionSettings() async {
    final tokenCtrl = TextEditingController(text: _tokenCtrl.text);
    // 扫码解析出的 relayUrl 静默存入内部值（UI 不展示地址），令牌回填输入框
    String? scannedUrl;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.i.connectSettings),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: tokenCtrl,
              decoration: InputDecoration(
                labelText: AppL10n.i.deviceTokenLabel,
                border: const OutlineInputBorder(),
              ),
            ),
            // 扫码配对仅移动端（web 无相机插件）
            if (!kIsWeb)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final info = await Navigator.of(ctx).push<PairInfo>(
                      MaterialPageRoute(builder: (_) => const PairScanPage()),
                    );
                    if (info != null) {
                      scannedUrl = info.relayUrl;
                      tokenCtrl.text = info.token;
                    }
                  },
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(AppL10n.i.scanPair),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppL10n.i.cancel)),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.i.saveAndConnect),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        if (scannedUrl != null) _urlCtrl.text = scannedUrl!;
        _tokenCtrl.text = tokenCtrl.text.trim();
      });
      await _connect();
    }
  }

  /// 首次配置页的扫码入口：relayUrl 静默写入内部值（UI 不展示），令牌回填并提示连接
  Future<void> _scanPair() async {
    final info = await Navigator.of(context).push<PairInfo>(
      MaterialPageRoute(builder: (_) => const PairScanPage()),
    );
    if (info == null) return;
    setState(() {
      _urlCtrl.text = info.relayUrl;
      _tokenCtrl.text = info.token;
    });
    _toast(AppL10n.i.qrRecognized);
  }

  void _openSession(BuildContext context, String? sessionId) {
    if (!widget.state.isDesktopConnected) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SessionPage(state: widget.state, sessionId: sessionId),
    ));
  }

  /// 重命名会话（弹输入框 → session.rename RPC）
  Future<void> _renameSession(SessionEntry s) async {
    final ctrl = TextEditingController(text: s.title ?? '');
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.i.renameSession),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: AppL10n.i.sessionName,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(AppL10n.i.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(AppL10n.i.confirm)),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    try {
      final resp = await widget.state.renameSession(s.id, newTitle);
      if (resp.payloadMap['ok'] != true) _toast(AppL10n.i.renameFailed(resp.payloadMap['error']));
    } catch (e) {
      _toast(AppL10n.i.renameError(e));
    }
  }

  /// 删除会话（确认框 → session.delete RPC）
  Future<void> _deleteSession(SessionEntry s) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.i.deleteSessionTitle),
        content: Text(AppL10n.i.deleteConfirm(s.displayTitle)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(AppL10n.i.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.i.delete),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      final resp = await widget.state.deleteSession(s.id);
      if (resp.payloadMap['ok'] == true) {
        _toast(AppL10n.i.deleted);
      } else {
        _toast(AppL10n.i.deleteFailed(resp.payloadMap['error']));
      }
    } catch (e) {
      _toast(AppL10n.i.deleteError(e));
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final connected = state.isDesktopConnected;
        return Scaffold(
          appBar: AppBar(
            title: Text(AppL10n.i.appTitle),
            actions: [
              _StatusChip(state: state),
              IconButton(
                icon: const Icon(Icons.settings),
                tooltip: AppL10n.i.isEn ? 'Settings' : '设置',
                onPressed: _openSettings,
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: Column(
            children: [
              if (connected && state.pendingApprovalCount > 0)
                Material(
                  color: Colors.amber.shade100,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.gpp_maybe_outlined, color: Colors.deepOrange),
                    title: Text(AppL10n.i.pendingApprovals(state.pendingApprovalCount),
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(AppL10n.i.tapToReview),
                    onTap: () {
                      final first =
                          state.approvals.values.firstWhere((a) => !a.resolved);
                      _openSession(context, first.sessionId);
                    },
                  ),
                ),
              Expanded(
                child: connected
                    ? _SnapshotView(
                        state: state,
                        onOpen: (sid) => _openSession(context, sid),
                        onRename: _renameSession,
                        onDelete: _deleteSession,
                      )
                    : _ConnectForm(
                        state: state,
                        tokenCtrl: _tokenCtrl,
                        onSubmit: () => _connect(),
                        onScan: _scanPair,
                      ),
              ),
            ],
          ),
          floatingActionButton: connected
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.add),
                  label: Text(AppL10n.i.newSession),
                  onPressed: () => _openSession(context, null),
                )
              : null,
        );
      },
    );
  }
}

/// 连接状态徽标
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (state.relayStatus) {
      RelayStatus.open when state.isDesktopConnected => (Colors.green, AppL10n.i.statusOpen),
      RelayStatus.open when state.checkingDesktop => (Colors.orange, AppL10n.i.statusCheckingDesktop),
      RelayStatus.open => (Colors.orange, AppL10n.i.statusDesktopOffline),
      RelayStatus.connecting => (Colors.orange, AppL10n.i.statusConnecting),
      RelayStatus.fatal => (Colors.red, AppL10n.i.statusAuthFailed),
      RelayStatus.closed => (Colors.orange, AppL10n.i.statusDisconnected),
      RelayStatus.idle => (Colors.grey, AppL10n.i.statusIdle),
    };
    return Row(children: [
      CircleAvatar(radius: 5, backgroundColor: color),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 13)),
    ]);
  }
}

/// 未连接时显示的设置面板（服务器地址已内置，不展示）
class _ConnectForm extends StatelessWidget {
  const _ConnectForm({
    required this.state,
    required this.tokenCtrl,
    required this.onSubmit,
    required this.onScan,
  });

  final AppState state;
  final TextEditingController tokenCtrl;
  final VoidCallback onSubmit;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final connecting = state.relayStatus == RelayStatus.connecting ||
        (!state.isDesktopConnected && state.checkingDesktop);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.phonelink_setup, size: 64),
              const SizedBox(height: 12),
              Text(AppL10n.i.connectTitle, textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(AppL10n.i.connectHint,
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 24),
              TextField(
                controller: tokenCtrl,
                decoration: InputDecoration(
                  labelText: AppL10n.i.deviceTokenLabel,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                ),
              ),
              // 扫码配对仅移动端（web 无相机插件）
              if (!kIsWeb)
                TextButton.icon(
                  onPressed: connecting ? null : () => onScan(),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: Text(AppL10n.i.scanPair),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: connecting ? null : onSubmit,
                icon: connecting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(connecting ? AppL10n.i.connecting : AppL10n.i.connect),
              ),
              if (state.desktopError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(state.desktopError!, textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.red)),
                ),
              if (state.relayError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    state.relayStatus == RelayStatus.fatal
                        ? AppL10n.i.authFailedDetail(state.relayError!)
                        : AppL10n.i.connectFailedDetail(state.relayError!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 已连接时显示的快照视图
class _SnapshotView extends StatelessWidget {
  const _SnapshotView({
    required this.state,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
  });

  final AppState state;
  final void Function(String sessionId) onOpen;
  final Future<void> Function(SessionEntry s) onRename;
  final Future<void> Function(SessionEntry s) onDelete;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (state.dirTree.isNotEmpty) ...[
          _SectionHeader(icon: Icons.folder_outlined, label: AppL10n.i.pcDirectory),
          ...state.dirTree.map((n) => _DirTile(node: n, state: state)),
        ],
        _SectionHeader(icon: Icons.smart_toy_outlined, label: AppL10n.i.sessions),
        if (state.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.inbox, size: 40, color: Colors.grey),
              const SizedBox(height: 8),
              Text(AppL10n.i.noSessions, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 4),
              Text(AppL10n.i.noSessionsHint,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          )
        else
          ...state.sessions.map((s) {
            final isFromApp = s.deletable;
            final accent = isFromApp ? Colors.blue : Colors.teal;
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                // 左侧色条区分来源：蓝=手机端创建，青=电脑端创建
                leading: Icon(
                  isFromApp ? Icons.smartphone : Icons.smart_toy_outlined,
                  color: accent,
                ),
                title: Row(children: [
                  Expanded(
                    child: Text(s.displayTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  // 回合运行中徽标（turn/start → turn/end 之间）
                  if (state.isBusy(s.id)) ...[
                    const SizedBox(width: 6),
                    const _RunningBadge(),
                  ],
                ]),
                subtitle: Text(
                  [
                    isFromApp ? AppL10n.i.fromPhone : AppL10n.i.fromPc,
                    if (s.model != null && s.model!.isNotEmpty) AppL10n.i.modelOf(s.model!),
                    if (s.updatedAt != null && s.updatedAt!.isNotEmpty) s.updatedAt!,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: accent, fontSize: 12),
                ),
                trailing: PopupMenuButton<String>(
                  tooltip: AppL10n.i.sessionActions,
                  onSelected: (v) {
                    if (v == 'rename') onRename(s);
                    if (v == 'delete') onDelete(s);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'rename', child: Row(children: [
                      const Icon(Icons.edit_outlined, size: 18),
                      const SizedBox(width: 8),
                      Text(AppL10n.i.rename),
                    ])),
                    const PopupMenuDivider(),
                    if (s.deletable)
                      PopupMenuItem<String>(value: 'delete', child: Row(children: [
                        const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        const SizedBox(width: 6),
                        Text(AppL10n.i.delete, style: const TextStyle(color: Colors.red)),
                      ]))
                    else
                      PopupMenuItem<String>(enabled: false, child: Row(children: [
                        const Icon(Icons.delete_forever_outlined, size: 18, color: Colors.grey),
                        const SizedBox(width: 6),
                        Text(AppL10n.i.pcSessionNoDelete, style: const TextStyle(color: Colors.grey)),
                      ])),
                  ],
                ),
                onTap: () => onOpen(s.id),
              ),
            );
          }),
      ],
    );
  }
}

/// 会话运行中徽标（列表卡片，turn/start → turn/end 之间显示）
class _RunningBadge extends StatelessWidget {
  const _RunningBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.green),
        ),
        const SizedBox(width: 4),
        Text(AppL10n.i.running, style: const TextStyle(color: Colors.green, fontSize: 11)),
      ]),
    );
  }
}

/// 区块小标题
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
      ]),
    );
  }
}

/// 快照目录树条目：目录可展开（含快照内 2 层子项），点箭头按钮深入浏览
class _DirTile extends StatelessWidget {
  const _DirTile({required this.node, required this.state});

  final DirNode node;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (!node.isDir) {
      return ListTile(
        dense: true,
        contentPadding: const EdgeInsets.only(left: 32, right: 16),
        leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
        title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.only(left: 12),
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: node.children.isEmpty
          ? Text(AppL10n.i.emptyShort, style: const TextStyle(fontSize: 11))
          : null,
      trailing: IconButton(
        icon: const Icon(Icons.open_in_new, size: 16),
        tooltip: AppL10n.i.browseDir,
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => DirBrowserPage(state: state, path: node.path, title: node.name),
        )),
      ),
      children: node.children.isEmpty
          ? const []
          : node.children.map((c) => _DirTile(node: c, state: state)).toList(),
    );
  }
}

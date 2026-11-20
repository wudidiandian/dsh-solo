/// 主页：连接设置 + 电脑快照（模型列表 + 会话列表 + 目录树）。
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../config/defaults.dart';
import '../config/workstation_store.dart';
import '../l10n/app_l10n.dart';
import '../relay/relay_client.dart';
import '../state/app_state.dart';
import '../state/notification_service.dart';
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
  String? _encryptionKey;
  String? _pairedToken;

  /// 当前网关选择：'cn' 国内 / 'intl' 国际（默认）/ null = 扫码指定的自定义节点
  String? _gateway;
  Future<void> _saveQueue = Future<void>.value();

  /// 当前工作站配置（null = 尚未入库的新配对）与已保存工作站列表
  AppConfig? _activeConfig;
  List<WorkstationEntry> _stations = [];

  /// 扫码/粘贴带来了新配对密钥：需要重新走设备注册
  bool _freshPairing = false;

  @override
  void initState() {
    super.initState();
    _activeConfig = widget.initialConfig;
    // 预填顺序：已保存配置 > 内置默认 relay 地址；令牌由扫码或手输填入
    _urlCtrl = TextEditingController(
      text: widget.initialConfig?.relayUrl ?? intlRelayUrl,
    );
    _tokenCtrl = TextEditingController(
      text: widget.initialConfig?.deviceToken ?? '',
    );
    _encryptionKey = widget.initialConfig?.encryptionKey;
    _pairedToken = widget.initialConfig?.deviceToken;
    _gateway = gatewayForUrl(widget.initialConfig?.relayUrl ?? intlRelayUrl);
    // 恢复上次选中的模型；之后每次切换都立即持久化（best-effort）
    final savedModelId = widget.initialConfig?.modelId;
    if (savedModelId != null && savedModelId.isNotEmpty) {
      widget.state.selectedModelId = savedModelId;
    }
    widget.state.onSelectedModelChanged = (id) async {
      try {
        await _saveCurrentConfig();
      } catch (_) {
        /* best-effort */
      }
    };
    // 设备身份注入 + 设备专属密钥持久化回调
    widget.state.deviceId = widget.initialConfig?.deviceId;
    widget.state.deviceRegistered =
        widget.initialConfig?.deviceRegistered ?? false;
    widget.state.onDeviceKeyReceived = (key) async {
      _encryptionKey = key;
      _activeConfig?.deviceRegistered = true;
      _activeConfig?.encryptionKey = key;
      try {
        await _saveCurrentConfig();
      } catch (_) {
        /* best-effort */
      }
    };
    unawaited(_loadStations());
    // 首次连上电脑后引导开启通知（一次性；用户主动同意才弹系统框）
    widget.state.addListener(_maybePromptNotifications);
    // 已保存过配置则自动连接
    if (widget.initialConfig != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    }
  }

  bool _notifyPromptHandled = false;

  void _maybePromptNotifications() {
    if (_notifyPromptHandled ||
        kIsWeb ||
        !widget.state.isDesktopConnected) {
      return;
    }
    _notifyPromptHandled = true;
    unawaited(_promptNotifications());
  }

  Future<void> _promptNotifications() async {
    final svc = NotificationService.instance;
    if (await svc.promptShown) return;
    // 系统层已允许（如 Android 12- 默认开启）：无需引导
    if (await svc.notificationsEnabled()) {
      await svc.markPromptShown();
      return;
    }
    if (!mounted) return;
    final enable = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.i.notifyPromptTitle),
        content: Text(AppL10n.i.notifyPromptBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.i.notNow),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.i.enableNotifications),
          ),
        ],
      ),
    );
    await svc.markPromptShown();
    if (enable == true) await svc.requestPermission();
  }

  Future<void> _loadStations() async {
    final ws = await loadWorkstations();
    if (mounted) setState(() => _stations = ws.stations);
  }

  String _stationLabel(WorkstationEntry s) {
    if (s.name.isNotEmpty) return s.name;
    final i = _stations.indexWhere((e) => e.id == s.id);
    return '${AppL10n.i.workstation} ${i + 1}';
  }

  @override
  void dispose() {
    widget.state.removeListener(_maybePromptNotifications);
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<bool> _connect() async {
    final pasted = parsePairUri(_tokenCtrl.text.trim());
    if (pasted != null) {
      _urlCtrl.text = pasted.relayUrl;
      _tokenCtrl.text = pasted.token;
      _pairedToken = pasted.token;
      _encryptionKey = pasted.encryptionKey;
      _freshPairing = true;
    }
    final url = _urlCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    final key = token == _pairedToken ? _encryptionKey : null;
    if (url.isEmpty) return false;
    // Persist a node even before pairing; never replace valid stored credentials
    // with an incomplete or unverified manual token.
    if (token.isNotEmpty && key == null) {
      widget.state.deviceId = null;
      widget.state.deviceRegistered = false;
      widget.state.connect(RelayClient(url: url, deviceToken: token));
      return false;
    }
    try {
      await _saveCurrentConfig();
    } catch (_) {
      if (mounted)
        _toast('无法安全保存连接设置，请重试 / Unable to save connection settings');
      return false;
    }
    if (!mounted ||
        url != _urlCtrl.text.trim() ||
        token != _tokenCtrl.text.trim())
      return false;
    if (token.isNotEmpty) {
      widget.state.deviceId = _activeConfig?.deviceId;
      widget.state.deviceRegistered =
          _activeConfig?.deviceRegistered ?? false;
      widget.state.connect(
        RelayClient(url: url, deviceToken: token, encryptionKey: key),
      );
    }
    return true;
  }

  Future<void> _saveCurrentConfig() async {
    final token = _tokenCtrl.text.trim();
    final key = token == _pairedToken ? _encryptionKey : null;
    if (token.isNotEmpty && key == null) return;
    final prev = _activeConfig;
    final config = AppConfig(
      relayUrl: _urlCtrl.text.trim(),
      deviceToken: token,
      encryptionKey: key,
      modelId: widget.state.selectedModelId,
      stationId: prev?.stationId,
      stationName: prev?.stationName,
      // 设备身份全局唯一（跟手机走，不跟配对走）：重复扫同一台电脑不新建设备；
      // 重新扫码（_freshPairing）时把老配置的独立 id 收敛到全局 id
      deviceId: key != null
          ? (_freshPairing
                ? await ensureDeviceId()
                : (prev?.deviceId ?? await ensureDeviceId()))
          : null,
      deviceRegistered: _freshPairing ? false : (prev?.deviceRegistered ?? false),
    );
    // Serialize writes so rapid node changes cannot leave an older choice saved.
    final next = _saveQueue
        .catchError((Object _) {})
        .then((_) async {
          await config.save();
          _activeConfig = config;
          _freshPairing = false;
          await _loadStations();
        });
    _saveQueue = next;
    return next;
  }

  /// 切换到另一台已配对电脑：重载配置并连接（会话/模型状态随设备变更清空）
  Future<void> _switchStation(String id) async {
    final ws = await loadWorkstations();
    final entry = ws.stations.where((s) => s.id == id).firstOrNull;
    if (entry == null) return;
    ws.activeId = id;
    await saveWorkstations(ws);
    if (!mounted) return;
    final config = entry.config;
    setState(() {
      _activeConfig = config;
      _freshPairing = false;
      _urlCtrl.text = config.relayUrl;
      _tokenCtrl.text = config.deviceToken;
      _encryptionKey = config.encryptionKey;
      _pairedToken = config.deviceToken;
      _gateway = gatewayForUrl(config.relayUrl);
      widget.state.selectedModelId = config.modelId;
    });
    await _connect();
  }

  /// 添加工作站：清空当前配对，走扫码/粘贴流程，保存时自动新建工作站
  Future<void> _addStation() async {
    setState(() {
      _activeConfig = null;
      _freshPairing = true;
      _tokenCtrl.clear();
      _encryptionKey = null;
      _pairedToken = null;
    });
    await _openConnectionSettings();
  }

  /// 管理工作站：重命名 / 删除
  Future<void> _manageStations() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          Future<void> reload() async {
            await _loadStations();
            setDlgState(() {});
          }

          return AlertDialog(
            title: Text(AppL10n.i.manageWorkstations),
            content: SizedBox(
              width: 320,
              child: _stations.isEmpty
                  ? Text(AppL10n.i.noStations)
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in _stations)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              s.id == _activeConfig?.stationId
                                  ? Icons.computer
                                  : Icons.computer_outlined,
                              size: 20,
                            ),
                            title: Text(_stationLabel(s)),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: AppL10n.i.rename,
                                  onPressed: () async {
                                    final ctrl = TextEditingController(text: s.name);
                                    final name = await showDialog<String>(
                                      context: ctx,
                                      builder: (dctx) => AlertDialog(
                                        title: Text(AppL10n.i.rename),
                                        content: TextField(
                                          controller: ctrl,
                                          autofocus: true,
                                          decoration: InputDecoration(
                                            hintText: _stationLabel(s),
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(dctx),
                                            child: Text(AppL10n.i.cancel),
                                          ),
                                          FilledButton(
                                            onPressed: () => Navigator.pop(
                                              dctx,
                                              ctrl.text.trim(),
                                            ),
                                            child: Text(AppL10n.i.save),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (name == null || name.isEmpty) return;
                                    final ws = await loadWorkstations();
                                    final e = ws.stations
                                        .where((x) => x.id == s.id)
                                        .firstOrNull;
                                    if (e == null) return;
                                    e.name = name;
                                    await saveWorkstations(ws);
                                    if (_activeConfig?.stationId == s.id) {
                                      _activeConfig?.stationName = name;
                                    }
                                    await reload();
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.red,
                                  ),
                                  tooltip: AppL10n.i.delete,
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: ctx,
                                      builder: (dctx) => AlertDialog(
                                        title: Text(AppL10n.i.delete),
                                        content: Text(
                                          AppL10n.i.deleteStationConfirm,
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, false),
                                            child: Text(AppL10n.i.cancel),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, true),
                                            child: Text(AppL10n.i.delete),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    final ws = await loadWorkstations();
                                    ws.stations.removeWhere((x) => x.id == s.id);
                                    final wasActive =
                                        _activeConfig?.stationId == s.id;
                                    if (wasActive) {
                                      ws.activeId = ws.stations.firstOrNull?.id;
                                    }
                                    await saveWorkstations(ws);
                                    await reload();
                                    if (!mounted) return;
                                    if (wasActive) {
                                      final next = ws.stations.firstOrNull;
                                      if (next != null) {
                                        Navigator.pop(ctx);
                                        await _switchStation(next.id);
                                      } else {
                                        setState(() {
                                          _activeConfig = null;
                                          _tokenCtrl.clear();
                                          _encryptionKey = null;
                                          _pairedToken = null;
                                        });
                                        widget.state.client?.stop();
                                      }
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppL10n.i.close),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Save and connect the selected node; both peers must use the same relay.
  Future<void> _switchGateway(String? g) async {
    final url = urlForGateway(g);
    if (url == null || url == _urlCtrl.text.trim()) return;
    setState(() {
      _gateway = g;
      _urlCtrl.text = url;
    });
    final saved = await _connect();
    if (mounted && saved) _toast(AppL10n.i.gatewaySwitched);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          state: widget.state,
          onConfigureConnection: _openConnectionSettings,
        ),
      ),
    );
  }

  Future<void> _openConnectionSettings() async {
    final tokenCtrl = TextEditingController(text: _tokenCtrl.text);
    // 扫码解析出的 relayUrl 静默存入内部值（UI 不展示地址），令牌回填输入框
    String? scannedUrl;
    String? scannedKey;
    String? scannedToken;
    // 弹窗内的网关选择（确定后才应用；扫码地址优先于手动选择）
    String? dlgGateway = _gateway;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppL10n.i.connectSettings),
        content: StatefulBuilder(
          builder: (ctx, setDlgState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GatewayPicker(
                gateway: dlgGateway,
                onChanged: (g) => setDlgState(() => dlgGateway = g),
              ),
              const SizedBox(height: 12),
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
                        scannedKey = info.encryptionKey;
                        scannedToken = info.token;
                        tokenCtrl.text = info.token;
                        // 扫码地址优先：回显其对应网关（自定义地址显示为「配对节点」）
                        setDlgState(
                          () => dlgGateway = gatewayForUrl(info.relayUrl),
                        );
                      }
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(AppL10n.i.scanPair),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.i.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppL10n.i.saveAndConnect),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        if (scannedUrl != null) {
          _urlCtrl.text = scannedUrl!;
          _gateway = gatewayForUrl(scannedUrl);
        } else if (dlgGateway != _gateway) {
          // 手动选择的网关：覆盖为内置节点地址
          _gateway = dlgGateway;
          final url = urlForGateway(dlgGateway);
          if (url != null) _urlCtrl.text = url;
        }
        if (scannedKey != null) {
          _encryptionKey = scannedKey;
          _pairedToken = scannedToken;
          _freshPairing = true;
        }
        _tokenCtrl.text = tokenCtrl.text.trim();
      });
      await _connect();
    }
  }

  /// 首次配置页的扫码入口：relayUrl 静默写入内部值（UI 不展示），令牌回填并提示连接
  Future<void> _scanPair() async {
    final info = await Navigator.of(
      context,
    ).push<PairInfo>(MaterialPageRoute(builder: (_) => const PairScanPage()));
    if (info == null) return;
    setState(() {
      _urlCtrl.text = info.relayUrl;
      _tokenCtrl.text = info.token;
      _encryptionKey = info.encryptionKey;
      _pairedToken = info.token;
      _gateway = gatewayForUrl(info.relayUrl);
    });
    _toast(AppL10n.i.qrRecognized);
  }

  void _openSession(BuildContext context, String? sessionId) {
    if (!widget.state.isDesktopConnected) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(state: widget.state, sessionId: sessionId),
      ),
    );
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
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppL10n.i.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(AppL10n.i.confirm),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    try {
      final resp = await widget.state.renameSession(s.id, newTitle);
      if (resp.payloadMap['ok'] != true)
        _toast(AppL10n.i.renameFailed(resp.payloadMap['error']));
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppL10n.i.cancel),
          ),
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
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
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
              PopupMenuButton<String>(
                icon: const Icon(Icons.computer),
                tooltip: AppL10n.i.workstations,
                onSelected: (v) {
                  if (v == '__add') {
                    _addStation();
                  } else if (v == '__manage') {
                    _manageStations();
                  } else {
                    _switchStation(v);
                  }
                },
                itemBuilder: (_) => [
                  for (final s in _stations)
                    PopupMenuItem(
                      value: s.id,
                      child: Row(
                        children: [
                          Icon(
                            s.id == _activeConfig?.stationId
                                ? Icons.check
                                : Icons.computer_outlined,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Flexible(child: Text(_stationLabel(s))),
                        ],
                      ),
                    ),
                  if (_stations.isNotEmpty) const PopupMenuDivider(),
                  PopupMenuItem(
                    value: '__add',
                    child: Row(
                      children: [
                        const Icon(Icons.add, size: 18),
                        const SizedBox(width: 8),
                        Text(AppL10n.i.addWorkstation),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: '__manage',
                    child: Row(
                      children: [
                        const Icon(Icons.tune, size: 18),
                        const SizedBox(width: 8),
                        Text(AppL10n.i.manageWorkstations),
                      ],
                    ),
                  ),
                ],
              ),
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
                    leading: const Icon(
                      Icons.gpp_maybe_outlined,
                      color: Colors.deepOrange,
                    ),
                    title: Text(
                      AppL10n.i.pendingApprovals(state.pendingApprovalCount),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(AppL10n.i.tapToReview),
                    onTap: () {
                      final first = state.approvals.values.firstWhere(
                        (a) => !a.resolved,
                      );
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
                        gateway: _gateway,
                        onGatewayChanged: (g) => _switchGateway(g),
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
      RelayStatus.open when state.isDesktopConnected => (
        Colors.green,
        AppL10n.i.statusOpen,
      ),
      RelayStatus.open when state.checkingDesktop => (
        Colors.orange,
        AppL10n.i.statusCheckingDesktop,
      ),
      RelayStatus.open => (Colors.orange, AppL10n.i.statusDesktopOffline),
      RelayStatus.connecting => (Colors.orange, AppL10n.i.statusConnecting),
      RelayStatus.fatal => (Colors.red, AppL10n.i.statusAuthFailed),
      RelayStatus.closed => (Colors.orange, AppL10n.i.statusDisconnected),
      RelayStatus.idle => (Colors.grey, AppL10n.i.statusIdle),
    };
    return Row(
      children: [
        if (state.client?.isEndToEndEncrypted == true &&
            state.isDesktopConnected)
          Tooltip(
            message: AppL10n.i.isEn ? 'End-to-end encrypted' : '端到端加密',
            child: Icon(Icons.lock_outline, size: 15, color: color),
          )
        else
          CircleAvatar(radius: 5, backgroundColor: color),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// 未连接时显示的设置面板（具体服务器地址不展示，仅展示网关选择）
class _ConnectForm extends StatelessWidget {
  const _ConnectForm({
    required this.state,
    required this.tokenCtrl,
    required this.gateway,
    required this.onGatewayChanged,
    required this.onSubmit,
    required this.onScan,
  });

  final AppState state;
  final TextEditingController tokenCtrl;
  final String? gateway;
  final ValueChanged<String?> onGatewayChanged;
  final VoidCallback onSubmit;
  final Future<void> Function() onScan;

  @override
  Widget build(BuildContext context) {
    final connecting =
        state.relayStatus == RelayStatus.connecting ||
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
              Text(
                AppL10n.i.connectTitle,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                AppL10n.i.connectHint,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: tokenCtrl,
                decoration: InputDecoration(
                  labelText: AppL10n.i.deviceTokenLabel,
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                ),
              ),
              const SizedBox(height: 16),
              _GatewayPicker(
                gateway: gateway,
                enabled: !connecting,
                onChanged: onGatewayChanged,
              ),
              const SizedBox(height: 8),
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
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(
                  connecting ? AppL10n.i.connecting : AppL10n.i.connect,
                ),
              ),
              if (state.desktopError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    state.desktopError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.red),
                  ),
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

/// 网关节点选择器：国际（默认）/ 国内两段式选择；
/// 扫码指定的自定义地址显示为「配对节点」，不展示完整 URL。
class _GatewayPicker extends StatelessWidget {
  const _GatewayPicker({
    required this.gateway,
    required this.onChanged,
    this.enabled = true,
  });

  final String? gateway;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final custom = gateway != 'cn' && gateway != 'intl';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppL10n.i.gatewayLabel,
          style: Theme.of(context).textTheme.labelMedium,
        ),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'intl', label: Text(AppL10n.i.gatewayINTL)),
            ButtonSegment(value: 'cn', label: Text(AppL10n.i.gatewayCN)),
          ],
          selected: {if (!custom) gateway!},
          onSelectionChanged: enabled ? (s) => onChanged(s.first) : null,
        ),
        if (custom) ...[
          const SizedBox(height: 4),
          Text(
            AppL10n.i.gatewayPair,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
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
          _SectionHeader(
            icon: Icons.folder_outlined,
            label: AppL10n.i.pcDirectory,
          ),
          ...state.dirTree.map((n) => _DirTile(node: n, state: state)),
        ],
        _SectionHeader(
          icon: Icons.smart_toy_outlined,
          label: AppL10n.i.sessions,
        ),
        if (state.sessions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.inbox, size: 40, color: Colors.grey),
                const SizedBox(height: 8),
                Text(
                  AppL10n.i.noSessions,
                  style: const TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  AppL10n.i.noSessionsHint,
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
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
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 回合运行中徽标（turn/start → turn/end 之间）
                    if (state.isBusy(s.id)) ...[
                      const SizedBox(width: 6),
                      const _RunningBadge(),
                    ],
                  ],
                ),
                subtitle: Text(
                  [
                    isFromApp ? AppL10n.i.fromPhone : AppL10n.i.fromPc,
                    if (s.model != null && s.model!.isNotEmpty)
                      AppL10n.i.modelOf(s.model!),
                    if (s.updatedAt != null && s.updatedAt!.isNotEmpty)
                      s.updatedAt!,
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
                    PopupMenuItem(
                      value: 'rename',
                      child: Row(
                        children: [
                          const Icon(Icons.edit_outlined, size: 18),
                          const SizedBox(width: 8),
                          Text(AppL10n.i.rename),
                        ],
                      ),
                    ),
                    const PopupMenuDivider(),
                    if (s.deletable && !state.capabilityOff('session.delete'))
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.red,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              AppL10n.i.delete,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ],
                        ),
                      )
                    else
                      PopupMenuItem<String>(
                        enabled: false,
                        child: Row(
                          children: [
                            const Icon(
                              Icons.delete_forever_outlined,
                              size: 18,
                              color: Colors.grey,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              AppL10n.i.pcSessionNoDelete,
                              style: const TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Colors.green,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            AppL10n.i.running,
            style: const TextStyle(color: Colors.green, fontSize: 11),
          ),
        ],
      ),
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
      child: Row(
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ],
      ),
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
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                DirBrowserPage(state: state, path: node.path, title: node.name),
          ),
        ),
      ),
      children: node.children.isEmpty
          ? const []
          : node.children.map((c) => _DirTile(node: c, state: state)).toList(),
    );
  }
}

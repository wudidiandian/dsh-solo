/// 全局应用状态：连接状态、快照数据、会话事件流、待审批。
///
/// 与 AgentCore（packages/agent/src/core.ts）的下行数据一一对应：
/// - agent.snapshot → 模型列表 + 会话列表 + 目录树（秒开数据源）
/// - session.event  → 按 seqId 去重后追加进对应会话的事件流
/// - sync.catchup   → 断线补发的事件（gap 时提示以最新快照为准）
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../l10n/app_l10n.dart';
import '../protocol/envelope.dart';
import '../relay/relay_client.dart';
import 'change_entry.dart';
import 'session_cache.dart';

/// 快照里的会话条目（防御性解析，字段缺失不崩溃）
class SessionEntry {
  final String id;
  final String? title;
  final String? model;
  final String? updatedAt;

  /// 手机端创建（拥有删除能力句柄）= true；电脑端 dsh 创建 = false
  final bool deletable;

  const SessionEntry({
    required this.id,
    this.title,
    this.model,
    this.updatedAt,
    this.deletable = false,
  });

  factory SessionEntry.from(Object? j) {
    if (j is Map) {
      final m = Map<String, dynamic>.from(j);
      final id = (m['id'] ?? m['sessionId'] ?? '').toString();
      return SessionEntry(
        id: id,
        title: m['title']?.toString(),
        model: (m['model'] ?? m['modelId'])?.toString(),
        updatedAt: m['updatedAt']?.toString(),
        deletable: m['deletable'] == true,
      );
    }
    return SessionEntry(id: j.toString());
  }

  String get displayTitle => (title == null || title!.isEmpty) ? id : title!;
}

/// 待审批条目
class ApprovalItem {
  ApprovalItem({
    required this.approvalId,
    required this.sessionId,
    required this.toolName,
    this.summary,
  });

  final String approvalId;
  final String sessionId;
  final String toolName;
  final String? summary;
  bool resolved = false;
}

/// 待发送 prompt 的附件（发送时随 session.prompt 携带给 agent）
class PendingAttachment {
  PendingAttachment({
    required this.kind,
    required this.name,
    this.path,
    this.url,
    this.size,
    this.mime,
    this.progress,
  });

  /// upload=手机上传已落盘 / file=电脑已有文件 / url=在线文档链接
  final String kind;
  final String name;
  final String? path;
  final String? url;
  final int? size;
  final String? mime;

  /// 上传进度 0..1（kind=upload 且上传中有效；null = 非上传中）
  double? progress;

  /// 转成 session.prompt.attachments 的 JSON（null 字段省略）
  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        if (path != null) 'path': path,
        if (url != null) 'url': url,
        if (size != null) 'size': size,
        if (mime != null) 'mime': mime,
      };
}

/// 快照目录树节点（防御性解析，字段缺失不崩溃）
class DirNode {
  const DirNode({
    required this.name,
    required this.path,
    required this.type,
    this.children = const [],
  });

  final String name;
  final String path;
  final String type; // 'dir' | 'file'
  final List<DirNode> children;

  bool get isDir => type == 'dir';

  static DirNode? from(Object? j) {
    if (j is! Map) return null;
    final m = Map<String, dynamic>.from(j);
    final name = (m['name'] ?? '').toString();
    if (name.isEmpty) return null;
    final rawChildren = (m['children'] as List?) ?? const [];
    return DirNode(
      name: name,
      path: (m['path'] ?? '').toString(),
      type: (m['type'] ?? 'file').toString(),
      children: rawChildren.map(DirNode.from).whereType<DirNode>().toList(),
    );
  }
}

/// 全局状态（ChangeNotifier + ListenableBuilder，零第三方依赖）
class AppState extends ChangeNotifier {
  RelayClient? client;

  RelayStatus relayStatus = RelayStatus.idle;
  String? relayError;
  String? relayUrl;
  String? deviceToken;

  /// 快照数据
  List<Map<String, dynamic>> models = [];
  List<SessionEntry> sessions = [];
  List<DirNode> dirTree = [];

  /// 手机端选中的模型 id（session.prompt 的 modelId；null = 用宿主默认模型）
  String? selectedModelId;

  /// 模型选择变化的持久化回调（UI 层注入，state 保持无 IO 依赖）
  void Function(String?)? onSelectedModelChanged;

  /// 切换选中模型（选择器 UI + 发送 prompt 时使用）
  void setSelectedModel(String? id) {
    final next = (id == null || id.isEmpty) ? null : id;
    if (selectedModelId == next) return;
    selectedModelId = next;
    onSelectedModelChanged?.call(next);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // 附件（2026-10-28）：+ 菜单（拍照/相册/电脑文件/链接）与上传
  // -------------------------------------------------------------------------

  /// 单文件上传上限：10MB（与 relay --max-upload / agent MAX_UPLOAD_SIZE 对齐；
  /// App 端限制只是友好提前报错，真正的硬限制在服务端）
  static const int maxUploadBytes = 10 << 20;

  /// 每条消息附件数上限（agent 侧 MAX_ATTACHMENTS_PER_PROMPT 同步为 3）
  static const int maxAttachmentsPerMessage = 3;

  /// 上传分块大小：256KB（base64 后 ~349KB，远小于 relay 4MB 读限制）
  static const int uploadChunkSize = 256 * 1024;

  /// 当前待发送的附件（会话页附件 chips 展示；发送成功后清空）
  final List<PendingAttachment> pendingAttachments = [];

  /// 待发送附件数（不含上传中失败的临时项）是否已满
  bool get attachmentsFull => pendingAttachments.length >= maxAttachmentsPerMessage;

  /// 添加附件（电脑文件 / 链接；上传的走 uploadBytes）
  void addAttachment(PendingAttachment att) {
    if (pendingAttachments.length >= maxAttachmentsPerMessage) {
      throw Exception(AppL10n.i.maxAttachments(maxAttachmentsPerMessage));
    }
    pendingAttachments.add(att);
    notifyListeners();
  }

  void removeAttachment(PendingAttachment att) {
    pendingAttachments.remove(att);
    notifyListeners();
  }

  /// 上传字节流（拍照/相册）：file.offer → 逐块 file.chunk（每块等 ack，
  /// 速率与 relay 字节桶对齐）→ 完成后返回电脑落盘路径。
  /// 上传中在 pendingAttachments 里展示进度条，失败自动移除。
  Future<String> uploadBytes(
    Uint8List bytes, {
    required String name,
    String? mime,
  }) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    // 断线重连窗口内不直接报错：等待自动重连（最多 8s）再上传
    await c.ensureOpen();
    if (bytes.length > maxUploadBytes) {
      throw Exception(AppL10n.i.fileTooLarge(bytes.length / (1 << 20)));
    }
    if (attachmentsFull) {
      throw Exception(AppL10n.i.maxAttachments(maxAttachmentsPerMessage));
    }
    final chunks = (bytes.length + uploadChunkSize - 1) ~/ uploadChunkSize;
    final transferId = newId();
    final placeholder = PendingAttachment(
      kind: 'upload',
      name: name,
      size: bytes.length,
      mime: mime,
      progress: 0,
    );
    pendingAttachments.add(placeholder);
    notifyListeners();
    try {
      final offer = await c.rpc(CmdAction.fileOffer, {
        'transferId': transferId,
        'name': name,
        'size': bytes.length,
        if (mime != null) 'mime': mime,
        'chunks': chunks,
      }, timeout: const Duration(seconds: 30));
      if (offer.payloadMap['ok'] != true) {
        throw Exception(offer.payloadMap['error']?.toString() ?? AppL10n.i.uploadRejected(''));
      }
      String path = '';
      // 上传节流：对齐 relay 字节令牌桶（upload-rate 默认 1MB/s，超速硬断连）。
      // "每块等 ack" 的自然节奏在低 RTT 网络（如 <256ms）下会超过 1MB/s——
      // 4MB burst 耗尽即被 relay 断开（表现为上传中途 "relay not connected"）。
      // 按 0.8MB/s 预节流（base64 膨胀 ~4/3 已计入），任何网络下不触达上限。
      const uploadWireChunk = uploadChunkSize * 4 ~/ 3; // base64 后报文字节
      const uploadRateBps = 800 * 1024;
      final startMs = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < chunks; i++) {
        final dueMs = startMs + (i * uploadWireChunk * 1000 ~/ uploadRateBps);
        final wait = dueMs - DateTime.now().millisecondsSinceEpoch;
        if (wait > 0) await Future.delayed(Duration(milliseconds: wait));
        final start = i * uploadChunkSize;
        final end = (start + uploadChunkSize) < bytes.length ? (start + uploadChunkSize) : bytes.length;
        final resp = await c.rpc(CmdAction.fileChunk, {
          'transferId': transferId,
          'index': i,
          'data': base64Encode(bytes.sublist(start, end)),
        }, timeout: const Duration(seconds: 60));
        if (resp.payloadMap['ok'] != true) {
          throw Exception(resp.payloadMap['error']?.toString() ?? AppL10n.i.chunkUploadFailed);
        }
        final result = resp.payloadMap['result'];
        path = (result is Map ? result['path'] : null)?.toString() ?? path;
        placeholder.progress = (i + 1) / chunks;
        notifyListeners();
      }
      if (path.isEmpty) throw Exception(AppL10n.i.uploadNoPath);
      // 换成带路径的最终条目（进度态 → 就绪态）
      final idx = pendingAttachments.indexOf(placeholder);
      pendingAttachments[idx] = PendingAttachment(
        kind: 'upload',
        name: name,
        path: path,
        size: bytes.length,
        mime: mime,
      );
      return path;
    } catch (e) {
      pendingAttachments.remove(placeholder);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// 每个会话的事件流
  final Map<String, List<Envelope>> _events = {};

  /// 每个会话已收到的最大 seqId（断线续传锚点）
  final Map<String, int> lastSeq = {};

  /// 存在事件缺口（环形缓冲已淘汰）的会话
  final Set<String> gapSessions = {};

  /// 正在跑回合的会话（turn/start 置位、turn/end 复位；仅实时事件维护，
  /// App 重启后不保留——重新连上后由后续事件自然校正）
  final Set<String> _busySessions = {};

  /// 会话是否正在运行回合（列表徽标 + 会话页等待指示）
  bool isBusy(String sessionId) => _busySessions.contains(sessionId);

  /// 逐字流缓冲（2026-10-28）：session.stream 的 text-delta 增量按会话累积。
  /// 瞬时帧不进 _events（不入历史），durable 的 assistant/message 到达或回合
  /// 结束时清空，由完整消息接管渲染。
  final Map<String, StringBuffer> _streaming = {};

  /// 会话当前流式增量文本（空 = 没有进行中的流式回复）
  String streamingTextOf(String sessionId) => _streaming[sessionId]?.toString() ?? '';

  /// 会话内 Agent 的文件变更（Diff 查看器数据源，从事件流即时提取）
  List<ChangeEntry> changesOf(String sessionId) =>
      extractChanges(eventsOf(sessionId));

  /// 待审批（approvalId → item）
  final Map<String, ApprovalItem> approvals = {};

  /// 待审批数量（横幅展示用）
  int get pendingApprovalCount => approvals.values.where((a) => !a.resolved).length;

  List<Envelope> eventsOf(String sessionId) => _events[sessionId] ?? const [];

  /// 处理 relay 下行的业务报文
  void applyEnvelope(Envelope env) {
    switch (env.type) {
      case MsgType.agentSnapshot:
        final p = env.payloadMap;
        models = ((p['models'] as List?) ?? [])
            .map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{'id': e.toString()})
            .toList();
        final list = ((p['sessions'] as List?) ?? []).map(SessionEntry.from).toList();
        // 从新到旧排序（新会话置顶；旧版 agent 快照未排序，此处兜底）
        list.sort((a, b) => (double.tryParse(b.updatedAt ?? '') ?? 0)
            .compareTo(double.tryParse(a.updatedAt ?? '') ?? 0));
        sessions = list;
        dirTree = ((p['dirTree'] as List?) ?? []).map(DirNode.from).whereType<DirNode>().toList();
        break;

      case MsgType.sessionEvent:
        _applySessionEvent(env);
        break;

      case MsgType.sessionStream:
        // 逐字流：瞬时增量，只更新缓冲不进历史（2026-10-28）
        final sid = env.sessionId ?? '';
        if (sid.isEmpty) break;
        final kind = env.payloadMap['kind']?.toString() ?? '';
        if (kind == 'text-delta') {
          _streaming.putIfAbsent(sid, () => StringBuffer()).write(env.payloadMap['text']?.toString() ?? '');
        } else if (kind == 'end') {
          _streaming.remove(sid);
        }
        // reasoning-delta 暂不展示（等待态已有“正在思考…”）
        break;

      case MsgType.syncCatchup:
        final p = env.payloadMap;
        final sid = (p['sessionId'] ?? env.sessionId ?? '').toString();
        if (p['gap'] == true) gapSessions.add(sid);
        for (final raw in (p['events'] as List? ?? [])) {
          if (raw is Map) {
            applyEnvelope(Envelope.fromJson(Map<String, dynamic>.from(raw)));
          }
        }
        break;
      default:
        return;
    }
    notifyListeners();
  }

  void _applySessionEvent(Envelope env) {
    final sid = env.sessionId ?? '';
    if (sid.isEmpty) return;
    final seq = env.seqId ?? 0;
    if (seq <= (lastSeq[sid] ?? 0)) return; // 重复 / 乱序报文丢弃
    lastSeq[sid] = seq;
    _events.putIfAbsent(sid, () => <Envelope>[]).add(env);

    if (env.payloadMap['kind'] == 'approval_request') {
      final id = (env.payloadMap['approvalId'] ?? env.payloadMap['id'] ?? '').toString();
      if (id.isNotEmpty && approvals[id] == null) {
        approvals[id] = ApprovalItem(
          approvalId: id,
          sessionId: sid,
          toolName: env.payloadMap['toolName']?.toString() ?? '',
          summary: env.payloadMap['summary']?.toString(),
        );
      }
    }
    // 审批已决（agent 侧回传的 resolved 事件，可选）
    final kind = env.payloadMap['kind'];
    // 回合运行状态：turn/start → 运行中；turn/end → 结束
    if (kind == 'turn/start') {
      _busySessions.add(sid);
    } else if (kind == 'turn/end') {
      _busySessions.remove(sid);
      // 回合结束：流式增量清空（无论正常完成还是报错，durable 消息已定局）
      _streaming.remove(sid);
    }
    // durable 完整消息落定：流式缓冲让位给 Markdown 气泡（防重复显示）
    if (kind == 'assistant/message' || kind == 'assistant/attempt') {
      _streaming.remove(sid);
    }
    if (kind == 'approval_resolved' || kind == 'approval.completed') {
      final id = (env.payloadMap['approvalId'] ?? env.payloadMap['id'] ?? '').toString();
      approvals[id]?.resolved = true;
    }
  }

  /// 连接 relay：创建客户端并接管回调
  void connect(RelayClient newClient) {
    client?.stop();
    client = newClient;
    relayUrl = newClient.url;
    deviceToken = newClient.deviceToken;
    newClient.onStatus = (s, detail) {
      relayStatus = s;
      relayError = detail;
      notifyListeners();
    };
    newClient.onHandshakeOk = onReconnected;
    newClient.onEnvelope = applyEnvelope;
    newClient.start();
    notifyListeners();
  }

  /// 每次握手成功后，对所有已知会话按 lastSeqId 请求差量补发
  void onReconnected() {
    for (final e in lastSeq.entries) {
      if (e.value > 0) client?.requestSync(e.key, e.value);
    }
  }

  /// 发送 prompt（sessionId 为空则由 agent 新建会话；modelId 缺省用
  /// selectedModelId，再缺省由 agent 侧回落宿主默认模型）。
  /// 待发送附件（pendingAttachments）随消息携带，发送成功后清空。
  Future<Envelope> sendPrompt(String text, {String? sessionId, String? modelId}) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    if (pendingAttachments.any((a) => a.progress != null)) {
      throw StateError(AppL10n.i.attachmentStillUploading);
    }
    final mid = modelId ?? selectedModelId;
    final atts = [for (final a in pendingAttachments) a.toJson()];
    return c.rpc(CmdAction.sessionPrompt, {
      if (sessionId != null) 'sessionId': sessionId,
      if (mid != null && mid.isNotEmpty) 'modelId': mid,
      'prompt': text,
      if (atts.isNotEmpty) 'attachments': atts,
    }, sessionId: sessionId).then((resp) {
      if (resp.payloadMap['ok'] == true) pendingAttachments.clear();
      notifyListeners();
      return resp;
    });
  }

  /// Fetch session history from the agent (memory buffer / on-disk jsonl).
  /// With [sinceSeqId] only events newer than it are returned (incremental sync).
  Future<Envelope> fetchHistory(String sessionId, {int? sinceSeqId}) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    return c.rpc(CmdAction.sessionHistory, {
      'sessionId': sessionId,
      if (sinceSeqId != null) 'sinceSeqId': sinceSeqId,
    }, sessionId: sessionId);
  }

  /// Render cached events immediately (fast open), replacing the in-memory
  /// list for this session. Live events newer than the cache keep flowing in.
  void applyCached(String sessionId, List<Envelope> events) {
    var maxSeq = 0;
    for (final e in events) {
      final seq = e.seqId ?? 0;
      if (seq > maxSeq) maxSeq = seq;
    }
    _events[sessionId] = List<Envelope>.of(events);
    if (maxSeq > (lastSeq[sessionId] ?? 0)) lastSeq[sessionId] = maxSeq;
    _streaming.remove(sessionId); // 历史重置后流式缓冲不再可信
    notifyListeners();
  }

  /// Merge newly fetched history events into the session's event list
  /// (incremental sync).
  ///
  /// Base = cached events (already rendered into memory on fast open, or
  /// loaded from the local cache as a fallback) + fetched events, deduped by
  /// seqId (fetched wins) and sorted ascending. The merged list is persisted
  /// to the local cache with the new lastSeqId so the next open is instant.
  Future<void> applyHistory(String sessionId, List<Envelope> history) async {
    final bySeq = <int, Envelope>{};
    for (final e in _events[sessionId] ?? const <Envelope>[]) {
      final seq = e.seqId ?? 0;
      if (seq > 0) bySeq[seq] = e;
    }
    for (final e in history) {
      final seq = e.seqId ?? 0;
      if (seq > 0) bySeq[seq] = e;
    }
    if (bySeq.isEmpty) return;
    final keys = bySeq.keys.toList()..sort();
    final merged = [for (final k in keys) bySeq[k]!];
    _events[sessionId] = merged;
    final maxSeq = keys.last;
    if (maxSeq > (lastSeq[sessionId] ?? 0)) lastSeq[sessionId] = maxSeq;
    notifyListeners();
    // Persist merged raw events (payload objects embed seqId) for next fast open
    try {
      await saveSessionCache(
        sessionId,
        maxSeq,
        [for (final e in merged) e.payloadMap],
      );
    } catch (_) {
      // Cache persistence is best-effort only
    }
  }

  /// 审批响应：允许 / 拒绝
  Future<Envelope> respondApproval(ApprovalItem item, bool approved) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    final resp = await c.rpc(
      CmdAction.approvalRespond,
      {'approvalId': item.approvalId, 'approved': approved},
      sessionId: item.sessionId,
    );
    item.resolved = true;
    notifyListeners();
    return resp;
  }

  /// 远程列目录
  Future<Envelope> listDir(String path) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    return c.rpc(CmdAction.fsListDir, {'path': path});
  }

  /// 重命名会话（写宿主 session/title 事件，App 端同步本地标题）
  Future<Envelope> renameSession(String sessionId, String title) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    final resp = await c.rpc(CmdAction.sessionRename, {
      'sessionId': sessionId,
      'title': title,
    });
    if (resp.payloadMap['ok'] == true) {
      final i = sessions.indexWhere((s) => s.id == sessionId);
      if (i >= 0) {
        final old = sessions[i];
        sessions[i] = SessionEntry(
          id: old.id,
          title: title,
          model: old.model,
          updatedAt: old.updatedAt,
          deletable: old.deletable,
        );
        notifyListeners();
      }
    }
    return resp;
  }

  /// 删除会话（dispose 宿主 agent；仅支持手机端本次运行创建的会话）
  Future<Envelope> deleteSession(String sessionId) async {
    final c = client;
    if (c == null) throw StateError('relay not connected');
    await c.ensureOpen();
    final resp = await c.rpc(CmdAction.sessionDelete, {'sessionId': sessionId});
    if (resp.payloadMap['ok'] == true) {
      sessions.removeWhere((s) => s.id == sessionId);
      _events.remove(sessionId);
      lastSeq.remove(sessionId);
      _busySessions.remove(sessionId);
      approvals.removeWhere((_, a) => a.sessionId == sessionId);
      notifyListeners();
    }
    return resp;
  }

  /// 清空某会话的事件缺口标记
  void clearGap(String sessionId) {
    gapSessions.remove(sessionId);
    notifyListeners();
  }
}

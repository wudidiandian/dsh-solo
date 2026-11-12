/// 会话详情页：事件流 + 审批卡片 + 输入栏。
///
/// - sessionId 为 null 表示「新会话」：发送第一条 prompt 后按 agent 返回的
///   sessionId 切换到真实会话。
/// - 事件按 kind 分桶渲染，连续的 text.delta 合并为一个气泡。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_l10n.dart';
import '../protocol/envelope.dart';
import '../state/app_state.dart';
import '../state/change_entry.dart';
import '../state/session_cache.dart';
import 'conversation_markdown.dart';
import 'interaction_card.dart';

class SessionPage extends StatefulWidget {
  const SessionPage({super.key, required this.state, this.sessionId});

  final AppState state;
  final String? sessionId;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  String? _activeSessionId;
  ProjectEntry? _selectedProject;
  bool _sending = false;
  final TextEditingController _inputCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  bool _followLatest = true;
  bool _pointerDown = false;
  bool _scrollScheduled = false;
  int _scrollEpoch = 0;
  String? _lastStream;
  bool? _lastRunning;
  String? _timelineRevision;
  List<Envelope>? _timelineEvents;
  List<Widget> _cachedBubbles = const [];
  Map<String, Widget> _textWidgets = {};
  final _markdownCache = ConversationMarkdownCache();
  static const _historyPageSize = 20;
  int _visibleBubbleCount = _historyPageSize;
  bool _loadingOlder = false;
  bool _olderLoadArmed = true;
  int _readerMotion = 0;
  VoidCallback? _restoreOlderAnchor;
  int _historyEpoch = 0;
  List<Widget>? _readingHistory;
  int? _readingThrough;
  int? _readingHostThrough;
  String? _readingEpoch;
  List<Envelope>? _windowSource;
  List<Envelope> _windowEvents = const [];
  int? _windowCursor;
  int _windowLength = -1;
  int? _windowLast;
  int? _windowHostThrough;
  String? _windowEpoch;

  List<Envelope> _historyWindow(List<Envelope> source) {
    final cursor = _remoteHasMore ? _olderCursor : null;
    final last = source.isEmpty ? null : source.last.seqId;
    if (!identical(_windowSource, source) ||
        _windowLength != source.length ||
        _windowLast != last ||
        _windowCursor != cursor) {
      _windowSource = source;
      _windowLength = source.length;
      _windowLast = last;
      final tail = source.isEmpty
          ? const <String, dynamic>{}
          : source.last.payloadMap;
      _windowHostThrough = (tail['seq'] as num?)?.toInt();
      _windowEpoch = tail['historyEpoch']?.toString();
      _windowCursor = cursor;
      _windowEvents = cursor == null
          ? source
          : source.where((e) => (e.seqId ?? 0) >= cursor).toList();
    }
    return _windowEvents;
  }

  String _readingStream = '';
  bool _readingRunning = false;

  /// Session whose history has been (or is being) fetched, guards duplicate requests
  String? _historyLoadedFor;
  bool _remoteHasMore = false;
  int? _olderCursor;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    _activeSessionId = widget.sessionId;
    _loadHistory();
  }

  @override
  void didUpdateWidget(SessionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sessionId != oldWidget.sessionId) {
      _activeSessionId = widget.sessionId;
      _selectedProject = null;
      _historyLoadedFor = null;
      _remoteHasMore = false;
      _olderCursor = null;
      _historyError = null;
      _followLatest = true;
      _timelineRevision = null;
      _textWidgets.clear();
      _markdownCache.clear();
      _visibleBubbleCount = _historyPageSize;
      _loadingOlder = false;
      _olderLoadArmed = true;
      _historyEpoch++;
      _restoreOlderAnchor = null;
      _readingHistory = null;
      _loadHistory();
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    _markdownCache.clear();
    _historyEpoch++;
    _restoreOlderAnchor = null;
    super.dispose();
  }

  /// Cache is a fast preview, never evidence that a missing range is synchronized.
  Future<void> _loadHistory() async {
    final sid = _activeSessionId;
    if (sid == null || _historyLoadedFor == sid) return;
    _historyLoadedFor = sid;
    try {
      final cached = await loadSessionCache(sid);
      if (!mounted || _activeSessionId != sid) return;
      if (cached != null) {
        widget.state.applyCached(sid, _historyEnvelopes(sid, cached.events));
      }
      await _fetchHistoryPage(sid);
    } catch (error) {
      if (!mounted || _activeSessionId != sid) return;
      setState(() {
        _historyLoadedFor = null;
        _historyError = AppL10n.i.isEn
            ? 'History sync failed. Tap to retry.'
            : '历史同步失败，点击重试';
      });
    }
  }

  List<Envelope> _historyEnvelopes(String sid, List rawEvents) => [
    for (final raw in rawEvents)
      if (raw is Map)
        Envelope(
          type: MsgType.sessionEvent,
          sessionId: sid,
          seqId: (raw['seqId'] as num?)?.toInt(),
          payload: Map<String, dynamic>.from(raw),
        ),
  ];

  Future<void> _fetchHistoryPage(String sid, {int? before}) async {
    final response = await widget.state.fetchHistoryPage(
      sid,
      beforeSeqId: before,
    );
    final payload = response.payloadMap;
    if (payload['ok'] != true) throw StateError('History unavailable');
    final result = payload['result'];
    if (result is! Map) throw StateError('Invalid history response');
    final raw = result['events'] as List? ?? const [];
    final history = _historyEnvelopes(sid, raw);
    if (!mounted || _activeSessionId != sid) return;
    // Only successful RPC pages advance the older-history cursor.
    final cursor = (result['beforeSeqId'] as num?)?.toInt();
    final more = result['hasMore'] == true;
    if (more && (cursor == null || (before != null && cursor >= before))) {
      throw StateError('History cursor did not advance');
    }
    final frozen = _readingHistory;
    final migrated =
        _readingEpoch != 'host-v1' &&
        history.any((e) => e.payloadMap['historyEpoch'] == 'host-v1');
    int? anchor = _readingThrough;
    if (migrated) {
      final first = history.first;
      final hostSeq = (first.payloadMap['seq'] as num?)?.toInt();
      anchor = _readingHostThrough == null || hostSeq == null
          ? null
          : first.seqId! - hostSeq + _readingHostThrough!;
    }
    final needsAnchor =
        frozen != null &&
        more &&
        anchor != null &&
        cursor != null &&
        cursor > anchor;
    await widget.state.applyHistory(sid, history);
    if (!mounted || _activeSessionId != sid) return;
    setState(() {
      _remoteHasMore = more;
      _olderCursor = cursor;
      _historyError = null;
      // Refresh a paused view after explicit history hydration, while preserving
      // its existing tail. Incoming live messages still cannot move this view.
      if (frozen != null && !needsAnchor) {
        final records = widget.state.eventsOf(sid);
        final migrated =
            _readingEpoch != 'host-v1' &&
            records.any((e) => e.payloadMap['historyEpoch'] == 'host-v1');
        _readingHistory = _buildBubbles([
          for (final e in records)
            if ((!more || cursor == null || (e.seqId ?? 0) >= cursor) &&
                (migrated
                    ? (_readingHostThrough == null ||
                          ((e.payloadMap['seq'] as num?)?.toInt() ?? 0) <=
                              _readingHostThrough!)
                    : (_readingThrough == null ||
                          (e.seqId ?? 0) <= _readingThrough!)))
              e,
        ]);
      }
    });
    if (needsAnchor) await _fetchHistoryPage(sid, before: cursor);
  }

  /// 发送 prompt
  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      if (_activeSessionId == null && _selectedProject == null) {
        if (!await _pickProject()) return;
      }
      if (!mounted) return;
      final resp = await widget.state.sendPrompt(
        text,
        sessionId: _activeSessionId,
        projectId: _activeSessionId == null ? _selectedProject?.id : null,
      );
      if (!mounted) return;
      final p = resp.payloadMap;
      final ok = p['ok'] == true;
      if (!ok) {
        _toast(AppL10n.i.sendFailed(p['error'] ?? AppL10n.i.unknownError));
        return;
      }
      if (_inputCtrl.text.trim() == text) _inputCtrl.clear();
      final result = p['result'];
      final newSid = result is Map ? result['sessionId']?.toString() : null;
      if (newSid != null && newSid.isNotEmpty && newSid != _activeSessionId) {
        setState(() => _activeSessionId = newSid);
      }
      setState(() {
        _followLatest = true;
        _readingHistory = null;
        _visibleBubbleCount = _historyPageSize;
        _historyEpoch++;
        _loadingOlder = false;
        _restoreOlderAnchor = null;
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted) _toast(AppL10n.i.sendError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  // -------------------------------------------------------------------------
  // 附件交互（2026-10-28）：+ 菜单 → 拍照 / 相册 / 选择项目 / 链接
  // -------------------------------------------------------------------------

  /// "+" 菜单：附件来源选择。附件已满时仅允许查看/移除。
  Future<void> _openAttachMenu() async {
    final state = widget.state;
    final full = state.attachmentsFull;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text(
                    AppL10n.i.addAttachment,
                    style: Theme.of(ctx).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Text(
                    '${state.pendingAttachments.length}/${AppState.maxAttachmentsPerMessage}',
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            ListTile(
              enabled: !full,
              dense: true,
              leading: const Icon(Icons.photo_camera_outlined),
              title: Text(AppL10n.i.cameraOption),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            ListTile(
              enabled: !full,
              dense: true,
              leading: const Icon(Icons.photo_outlined),
              title: Text(AppL10n.i.galleryTitle),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              enabled: !_sending,
              dense: true,
              leading: const Icon(Icons.folder_open),
              title: Text(AppL10n.i.selectProject),
              subtitle: Text(
                AppL10n.i.selectProjectHint,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, 'project'),
            ),
            ListTile(
              enabled: !full,
              dense: true,
              leading: const Icon(Icons.link),
              title: Text(AppL10n.i.linkTitle),
              subtitle: Text(
                AppL10n.i.linkSubtitle,
                style: const TextStyle(fontSize: 11),
              ),
              onTap: () => Navigator.pop(ctx, 'link'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null) return;
    switch (action) {
      case 'camera':
        await _pickImage(ImageSource.camera);
      case 'gallery':
        await _pickImage(ImageSource.gallery);
      case 'project':
        await _pickProject();
      case 'link':
        await _addLinkDialog();
    }
  }

  /// 拍照 / 相册：压缩（2048px、质量 70）→ 大小校验 → 分块上传
  Future<void> _pickImage(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2048,
        imageQuality: 70,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      await widget.state.uploadBytes(
        bytes,
        name: picked.name,
        mime: picked.mimeType,
      );
    } catch (e) {
      _toast(AppL10n.i.uploadFailed(e));
    }
  }

  /// 选择已有桌面项目，首条消息发送时创建会话。
  Future<bool> _pickProject() async {
    final project = await showDialog<ProjectEntry>(
      context: context,
      builder: (_) => _ProjectPickerDialog(state: widget.state),
    );
    if (project == null || !mounted) return false;
    setState(() {
      _selectedProject = project;
      _activeSessionId = null;
      _historyLoadedFor = null;
    });
    return true;
  }

  /// 在线文档链接输入
  Future<void> _addLinkDialog() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          AppL10n.i.linkDialogTitle,
          style: const TextStyle(fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            hintText: AppL10n.i.linkHint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppL10n.i.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(AppL10n.i.add),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    if (!RegExp(r'^https?://').hasMatch(url)) {
      _toast(AppL10n.i.invalidUrl);
      return;
    }
    try {
      widget.state.addAttachment(
        PendingAttachment(
          kind: 'url',
          name: url.replaceFirst(RegExp(r'^https?://'), '').split('/').last,
          url: url,
        ),
      );
    } catch (e) {
      _toast('$e');
    }
  }

  /// 审批响应
  Future<void> _respond(ApprovalItem item, bool approved) async {
    try {
      final resp = await widget.state.respondApproval(item, approved);
      final ok = resp.payloadMap['ok'] == true;
      _toast(
        ok
            ? AppL10n.i.approveOk(approved)
            : AppL10n.i.approveFailed(resp.payloadMap['error']),
      );
    } catch (e) {
      _toast(AppL10n.i.approveError(e));
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  void _scrollToBottom([int remainingLayouts = 5]) {
    if (_scrollScheduled || !_followLatest || _pointerDown) return;
    _scrollScheduled = true;
    final epoch = _scrollEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (epoch != _scrollEpoch) {
        if (mounted && _followLatest && !_pointerDown) _scrollToBottom();
        return;
      }
      if (!mounted ||
          !_followLatest ||
          _pointerDown ||
          !_scrollCtrl.hasClients ||
          _scrollCtrl.position.isScrollingNotifier.value) {
        return;
      }
      final position = _scrollCtrl.position;
      if ((position.minScrollExtent - position.pixels).abs() > 0.5) {
        _scrollCtrl.jumpTo(position.minScrollExtent);
      }
      // Coalesce updates; never let queued layout corrections override a drag.
      if (remainingLayouts > 0) {
        _scrollToBottom(remainingLayouts - 1);
        WidgetsBinding.instance.scheduleFrame();
      }
    });
  }

  void _pauseFollowing() {
    _scrollEpoch++;
    if (_followLatest) {
      setState(() {
        // Keep the inspected timeline stable while new output arrives below it.
        _readingHistory = List.of(_cachedBubbles);
        final existing = widget.state.eventsOf(_activeSessionId ?? '');
        _readingThrough = existing.isEmpty ? null : existing.last.seqId;
        _readingHostThrough = _windowHostThrough;
        _readingEpoch = _windowEpoch;
        _readingStream = _lastStream ?? '';
        _readingRunning = _lastRunning ?? false;
        _followLatest = false;
      });
    }
  }

  void _resumeFollowingIfAtBottom() {
    if (_pointerDown ||
        !_scrollCtrl.hasClients ||
        _scrollCtrl.position.isScrollingNotifier.value) {
      return;
    }
    final follow = _scrollCtrl.position.extentBefore < 60;
    if (_followLatest != follow) {
      setState(() {
        _followLatest = follow;
        if (follow) _readingHistory = null;
      });
    }
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _olderLoadArmed = true;
      _pauseFollowing();
    } else if (notification is ScrollEndNotification) {
      _restoreOlderAnchor?.call();
      _resumeFollowingIfAtBottom();
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _readerMotion++;
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null &&
        notification.metrics.extentAfter > 240) {
      _olderLoadArmed = true;
    }
    if (notification is ScrollUpdateNotification &&
        _olderLoadArmed &&
        notification.metrics.extentAfter < 160) {
      _loadOlderMessages();
    }
    return false;
  }

  Future<void> _loadOlderMessages() async {
    var history = _readingHistory ?? _cachedBubbles;
    if (_loadingOlder) return;
    if (_visibleBubbleCount >= history.length && _remoteHasMore) {
      final sid = _activeSessionId;
      if (sid == null) return;
      setState(() => _loadingOlder = true);
      try {
        await _fetchHistoryPage(sid, before: _olderCursor);
      } catch (_) {
        if (mounted && sid == _activeSessionId)
          setState(() {
            _historyError = AppL10n.i.isEn
                ? 'History sync failed. Tap to retry.'
                : '历史同步失败，点击重试';
          });
      } finally {
        if (mounted && sid == _activeSessionId)
          setState(() => _loadingOlder = false);
      }
      if (!mounted || sid != _activeSessionId) return;
      history =
          _readingHistory ??
          _buildBubbles(_historyWindow(widget.state.eventsOf(sid)));
    }
    if (_visibleBubbleCount >= history.length) return;
    _olderLoadArmed = false;
    final epoch = _historyEpoch;
    final motion = _readerMotion;
    final anchorOffset = _scrollCtrl.hasClients ? _scrollCtrl.offset : null;
    final end = history.length - _visibleBubbleCount;
    final start = (end - _historyPageSize).clamp(0, end);
    final older = history.sublist(start, end);
    setState(() => _loadingOlder = true);
    // Let the loading indicator paint before parsing the next local page.
    await WidgetsBinding.instance.endOfFrame;
    for (final bubble in older.reversed) {
      if (!mounted || epoch != _historyEpoch) return;
      if (bubble is _TextBubble) await _markdownCache.document(bubble.text);
      await Future<void>.delayed(Duration.zero);
    }
    if (!mounted || epoch != _historyEpoch) return;
    setState(() {
      _visibleBubbleCount += older.length;
      _loadingOlder = false;
    });
    _restoreOlderAnchor = () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            epoch != _historyEpoch ||
            motion != _readerMotion ||
            _pointerDown ||
            !_scrollCtrl.hasClients ||
            anchorOffset == null) {
          _restoreOlderAnchor = null;
          return;
        }
        // Never interrupt an active drag/fling. Retry at its natural end.
        if (_scrollCtrl.position.isScrollingNotifier.value) return;
        _restoreOlderAnchor = null;
        final position = _scrollCtrl.position;
        _scrollCtrl.jumpTo(
          anchorOffset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      });
    };
    _restoreOlderAnchor!();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final sid = _activeSessionId;
        final events = _historyWindow(
          sid == null ? const <Envelope>[] : state.eventsOf(sid),
        );
        final streaming = sid == null ? '' : state.streamingTextOf(sid);
        final running = sid != null && state.isBusy(sid);
        final revision =
            '$sid:${events.length}:${events.isEmpty ? 0 : events.last.seqId}';
        if (_timelineRevision != revision ||
            !identical(_timelineEvents, events)) {
          _timelineRevision = revision;
          _timelineEvents = events;
          final oldCount = _cachedBubbles.length;
          _cachedBubbles = _buildBubbles(events);
          if (_followLatest) {
            _visibleBubbleCount = _historyPageSize;
          } else if (_readingHistory == null &&
              oldCount > 0 &&
              _cachedBubbles.length > oldCount) {
            _visibleBubbleCount += _cachedBubbles.length - oldCount;
          }
          if (_followLatest) _scrollToBottom();
        }
        if (_lastStream != streaming || _lastRunning != running) {
          _lastStream = streaming;
          _lastRunning = running;
          if (_followLatest) _scrollToBottom();
        }

        final pendingInteractions = state.interactions.values
            .where((r) => r['sessionId'] == sid)
            .toList();
        final approvalsThis = state.approvals.values
            .where((a) => a.sessionId == sid && !a.resolved)
            .toList();

        // Incoming messages do not shift a paused, reverse-scrolling viewport.
        final history = _readingHistory ?? _cachedBubbles;
        final visibleStream = _readingHistory == null
            ? streaming
            : _readingStream;
        final visibleRunning = _readingHistory == null
            ? running
            : _readingRunning;
        final bubbles = [
          ...history.skip(
            (history.length - _visibleBubbleCount).clamp(0, history.length),
          ),
          if (visibleStream.isNotEmpty)
            _StreamingBubble(text: visibleStream, running: visibleRunning),
          if (visibleStream.isEmpty &&
              visibleRunning &&
              pendingInteractions.isEmpty &&
              approvalsThis.isEmpty)
            const _ThinkingLine(),
        ];

        final changes = sid == null
            ? const <ChangeEntry>[]
            : state.changesOf(sid);

        return Scaffold(
          appBar: AppBar(
            title: Text(
              AppL10n.i.sessionTitle(sid),
              style: const TextStyle(fontSize: 16),
            ),
            actions: [
              if (changes.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.difference_outlined),
                  tooltip: AppL10n.i.changesTitle,
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _ChangesPage(entries: changes),
                    ),
                  ),
                ),
            ],
          ),
          body: Column(
            children: [
              if (!state.isDesktopConnected)
                Material(
                  color: Colors.amber.shade100,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.link_off),
                    title: Text(AppL10n.i.desktopUnavailable),
                  ),
                ),
              if (_historyError != null)
                TextButton.icon(
                  key: const ValueKey('retry-history-sync'),
                  onPressed: _historyLoadedFor == null
                      ? _loadHistory
                      : _loadOlderMessages,
                  icon: const Icon(Icons.refresh),
                  label: Text(_historyError!),
                ),
              if (state.gapSessions.contains(sid))
                Material(
                  color: Colors.blueGrey.shade50,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.info_outline),
                    title: Text(
                      AppL10n.i.gapBanner,
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: TextButton(
                      onPressed: () => state.clearGap(sid!),
                      child: Text(AppL10n.i.gotIt),
                    ),
                  ),
                ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: bubbles.isEmpty && approvalsThis.isEmpty
                          ? Center(
                              child: Text(
                                sid == null
                                    ? AppL10n.i.firstTaskHint
                                    : AppL10n.i.noNewEvents,
                                style: const TextStyle(color: Colors.grey),
                              ),
                            )
                          : NotificationListener<ScrollNotification>(
                              onNotification: _onScroll,
                              child: Listener(
                                onPointerDown: (_) {
                                  _pointerDown = true;
                                  _pauseFollowing();
                                },
                                onPointerUp: (_) {
                                  _pointerDown = false;
                                  _resumeFollowingIfAtBottom();
                                },
                                onPointerCancel: (_) {
                                  _pointerDown = false;
                                  _resumeFollowingIfAtBottom();
                                },
                                child: ListView.builder(
                                  reverse: true,
                                  scrollCacheExtent:
                                      const ScrollCacheExtent.pixels(400),
                                  key: PageStorageKey('conversation-$sid'),
                                  controller: _scrollCtrl,
                                  padding: const EdgeInsets.all(12),
                                  itemCount:
                                      bubbles.length +
                                      approvalsThis.length +
                                      (_visibleBubbleCount < history.length ||
                                              _remoteHasMore ||
                                              _historyError != null
                                          ? 1
                                          : 0),
                                  itemBuilder: (context, index) {
                                    if (index < approvalsThis.length) {
                                      return _ApprovalCard(
                                        item: approvalsThis[index],
                                        onRespond: _respond,
                                      );
                                    }
                                    final messageIndex =
                                        index - approvalsThis.length;
                                    if (messageIndex < bubbles.length) {
                                      return bubbles[bubbles.length -
                                          1 -
                                          messageIndex];
                                    }
                                    return Center(
                                      child: _loadingOlder
                                          ? const Padding(
                                              padding: EdgeInsets.all(16),
                                              child: SizedBox.square(
                                                key: ValueKey(
                                                  'older-history-loading',
                                                ),
                                                dimension: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 2,
                                                    ),
                                              ),
                                            )
                                          : TextButton(
                                              key: const ValueKey(
                                                'load-older-history',
                                              ),
                                              onPressed:
                                                  _historyError != null &&
                                                      _historyLoadedFor == null
                                                  ? _loadHistory
                                                  : _loadOlderMessages,
                                              child: Text(
                                                _historyError ??
                                                    (AppL10n.i.isEn
                                                        ? 'Load earlier messages'
                                                        : '加载更早消息'),
                                              ),
                                            ),
                                    );
                                  },
                                ),
                              ),
                            ),
                    ),
                    if (!_followLatest)
                      Positioned(
                        right: 12,
                        bottom: 8,
                        child: FilledButton.tonalIcon(
                          key: const ValueKey('return-to-latest'),
                          onPressed: () {
                            setState(() {
                              _followLatest = true;
                              _readingHistory = null;
                              _visibleBubbleCount = _historyPageSize;
                              _historyEpoch++;
                              _loadingOlder = false;
                              _restoreOlderAnchor = null;
                            });
                            _scrollToBottom();
                          },
                          icon: const Icon(Icons.arrow_downward, size: 16),
                          label: Text(AppL10n.i.isEn ? 'Latest' : '回到最新'),
                        ),
                      ),
                  ],
                ),
              ),
              if (pendingInteractions.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight:
                        (MediaQuery.sizeOf(context).height -
                            MediaQuery.viewInsetsOf(context).bottom -
                            kToolbarHeight -
                            MediaQuery.paddingOf(context).top) *
                        0.40,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final request in pendingInteractions)
                          InteractionCard(
                            key: ValueKey(request['id']),
                            request: request,
                            onRespond: (response) =>
                                state.respondInteraction(request, response),
                          ),
                      ],
                    ),
                  ),
                ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_selectedProject != null)
                        TextButton.icon(
                          onPressed: _sending ? null : _pickProject,
                          icon: const Icon(Icons.folder_outlined, size: 18),
                          label: Text(_selectedProject!.title),
                        ),
                      _ModelPicker(state: state),
                      _AttachmentStrip(
                        state: state,
                        onRemoved: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            tooltip: AppL10n.i.addAttachment,
                            onPressed: _openAttachMenu,
                          ),
                          Expanded(
                            child: TextField(
                              controller: _inputCtrl,
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _send(),
                              decoration: InputDecoration(
                                hintText: AppL10n.i.taskHint,
                                border: const OutlineInputBorder(),
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            icon: const Icon(Icons.send),
                            tooltip: AppL10n.i.send,
                            onPressed: _send,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 把事件流折叠成展示气泡（连续 text.delta 合并）
  List<Widget> _buildBubbles(List<Envelope> events) {
    final widgets = <Widget>[];
    final textBuf = StringBuffer();
    final thoughtBuf = StringBuffer();
    final details = <Widget>[];
    String? detailId;
    final nextTextWidgets = <String, Widget>{};
    Widget textBubble(String text) => nextTextWidgets.putIfAbsent(
      text,
      () =>
          _textWidgets[text] ?? _TextBubble(text: text, cache: _markdownCache),
    );
    void flushDetails() {
      if (details.isEmpty) return;
      widgets.add(
        _ExecutionSteps(
          key: ValueKey('steps-$detailId'),
          storageId: '$detailId',
          steps: List.of(details),
        ),
      );
      details.clear();
      detailId = null;
    }

    void flush() {
      if (textBuf.isNotEmpty) {
        widgets.add(textBubble(textBuf.toString()));
        textBuf.clear();
      }
      if (thoughtBuf.isNotEmpty) {
        widgets.add(_ThoughtBubble(text: thoughtBuf.toString()));
        thoughtBuf.clear();
      }
    }

    for (final env in events) {
      final p = env.payloadMap;
      final kind = p['kind']?.toString() ?? '';
      final data = p['data'];
      if (const [
        'user/message',
        'assistant/message',
        'text.delta',
        'thought.delta',
        'turn/end',
        'turn.completed',
        'turn.failed',
        'approval_request',
        'ask_user',
      ].contains(kind)) {
        flushDetails();
      }
      detailId ??= '${env.sessionId}:${env.seqId}';
      switch (kind) {
        // —— 宿主真实事件（dsh session/event，data 为事件载荷）——
        case 'user/message':
          flush();
          // 只渲染真实用户发言（source.kind == 'user'）。宿主会在回合开头
          // 注入模型可见上下文（agent-instructions 指令基线、skill-catalog
          // 技能目录、time-context 时间快照、runtime-context 工作目录说明
          // 等），电脑端 UI 不显示它们，这里同样跳过，否则电脑端发起的会话
          // 开头会多出一堆“系统提示词”气泡。
          final src = data is Map
              ? (data['source'] is Map ? data['source'] as Map : const {})
              : const {};
          if (src['kind']?.toString() != 'user') break;
          final text = _messageText(data);
          if (text != null) widgets.add(_UserBubble(text: text));
          break;
        case 'assistant/message':
          flush();
          final text = _messageText(data);
          if (text != null) widgets.add(textBubble(text));
          break;
        case 'tool/call':
          flush();
          final d = data is Map ? data : const {};
          final name = d['name']?.toString() ?? '';
          details.add(
            _ToolLine(
              icon: Icons.build,
              color: Colors.blueGrey,
              text: AppL10n.i.toolCall(name).trim(),
            ),
          );
          break;
        case 'tool/result':
          flush();
          final d = data is Map ? data : const {};
          final failed = d['isError'] == true || d['error'] != null;
          details.add(
            _ToolLine(
              icon: failed
                  ? Icons.error_outline
                  : Icons.subdirectory_arrow_right,
              color: failed ? Colors.red : Colors.grey,
              text: failed ? AppL10n.i.toolFailed : AppL10n.i.toolResult,
            ),
          );
          break;
        case 'turn/end':
          flush();
          // 宿主真实结构: data = { turn, reason: { kind: completed|blocked|max-tokens|error, error? } }
          final d = data is Map ? data : const {};
          final r = d['reason'] ?? d['kind'];
          final reason = r is Map
              ? (r['kind']?.toString() ?? '')
              : (r?.toString() ?? '');
          final failed = reason.isNotEmpty && reason != 'completed';
          var errText = AppL10n.i.turnEnded(reason);
          if (failed && r is Map && r['error'] != null) {
            final e = r['error'];
            final msg = e is Map
                ? (e['message']?.toString() ?? '')
                : e.toString();
            if (msg.isNotEmpty) errText = AppL10n.i.turnEndWith(reason, msg);
          }
          widgets.add(_TurnLine(ok: !failed, error: failed ? errText : null));
          break;
        case 'turn/start':
          // 回合开始：运行态由 AppState._busySessions 维护（isBusy），
          // 这里无需处理。“正在思考…”/流式打字机由循环结束后按 turnRunning 追加。
          break;
        case 'step/start':
        case 'step/end':
        case 'agent/inbox/spliced':
        case 'system/message':
        case 'session/title':
        case 'session/title-llm-request':
        case 'session-log-deepseek/delivery-accepted':
        case 'request/header':
        case 'request/context':
        case 'permission/preset':
        case 'sandbox/mode':
        case 'approval/policy':
        case 'working-directory/change':
        case 'model/selection': // 电脑端切换模型（2026-10-28）：宿主系统事件，不上屏
          // 宿主内部流程事件：不上屏
          break;
        // —— 旧协议（保留兼容）——
        case 'text.delta':
          textBuf.write(_deltaText(env));
          break;
        case 'thought.delta':
          thoughtBuf.write(_deltaText(env));
          break;
        case 'tool.started':
          flush();
          details.add(
            _ToolLine(
              icon: Icons.build,
              color: Colors.blueGrey,
              text: AppL10n.i
                  .toolStarted(
                    '${env.payloadMap['toolName'] ?? ''} ${env.payloadMap['summary'] ?? ''}',
                  )
                  .trim(),
            ),
          );
          break;
        case 'tool.completed':
          flush();
          details.add(
            _ToolLine(
              icon: Icons.check_circle,
              color: Colors.green,
              text: AppL10n.i.toolCompletedLabel,
            ),
          );
          break;
        case 'approval_request':
        case 'ask_user':
          flush(); // 审批卡片单独渲染，不在这里
          break;
        case 'turn.completed':
          flush();
          widgets.add(const _TurnLine(ok: true));
          break;
        case 'turn.failed':
          flush();
          widgets.add(
            _TurnLine(ok: false, error: env.payloadMap['error']?.toString()),
          );
          break;
        default:
          // 未知事件：显示原始 kind（保持信息不丢）
          flush();
          details.add(
            _ToolLine(
              icon: Icons.circle,
              color: Colors.grey,
              text: kind.isEmpty ? AppL10n.i.emptyEvent : kind,
            ),
          );
      }
    }
    flush();
    flushDetails();
    _textWidgets = nextTextWidgets;
    return widgets;
  }

  /// 从消息载荷提取正文：data 可能是消息本身（user/message），
  /// 也可能包一层 message 字段（assistant/message 的 {turn,step,message}）
  static String? _messageText(Object? data) {
    if (data is! Map) return null;
    final m = data['message'] is Map ? data['message'] as Map : data;
    final content = m['content'];
    if (content is! List) return null;
    final buf = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        final t = (block['text'] ?? '').toString();
        if (t.isNotEmpty) {
          if (buf.isNotEmpty) buf.write('\n\n');
          buf.write(t);
        }
      }
    }
    return buf.isEmpty ? null : buf.toString();
  }

  /// 从 delta 事件里尽力提取文本
  static String _deltaText(Envelope env) {
    final p = env.payloadMap;
    for (final k in const ['text', 'delta', 'content', 'data', 'chunk']) {
      final v = p[k];
      if (v is String) return v;
    }
    return '';
  }
}

class _ExecutionSteps extends StatelessWidget {
  const _ExecutionSteps({
    super.key,
    required this.storageId,
    required this.steps,
  });
  final String storageId;
  final List<Widget> steps;
  @override
  Widget build(BuildContext context) {
    final failed = steps.whereType<_ToolLine>().any(
      (s) => s.color == Colors.red,
    );
    return ExpansionTile(
      // ExpansionTile stores a bool; ScrollPosition stores a double. Give each
      // group a distinct PageStorage namespace instead of sharing the list's.
      key: PageStorageKey('execution-steps-$storageId'),
      dense: true,
      initiallyExpanded: false,
      leading: Icon(
        failed ? Icons.error_outline : Icons.build_outlined,
        size: 18,
        color: failed ? Colors.orange : Colors.blueGrey,
      ),
      title: Text(
        AppL10n.i.isEn ? 'Steps (${steps.length})' : '执行步骤（${steps.length}）',
        style: const TextStyle(fontSize: 13),
      ),
      subtitle: failed
          ? Text(
              AppL10n.i.isEn ? 'Some steps failed' : '部分步骤失败',
              style: const TextStyle(fontSize: 12, color: Colors.orange),
            )
          : null,
      children: steps,
    );
  }
}

/// 审批卡片
class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.item, required this.onRespond});

  final ApprovalItem item;
  final Future<void> Function(ApprovalItem, bool) onRespond;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.deepOrange.shade50,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.gpp_maybe_outlined, color: Colors.deepOrange),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppL10n.i.pendingApprovalCard(item.toolName),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            if (item.summary != null && item.summary!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 28),
                child: SelectableText(item.summary!),
              ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.close, size: 18),
                  label: Text(AppL10n.i.deny),
                  onPressed: () => onRespond(item, false),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: Text(AppL10n.i.allow),
                  onPressed: () => onRespond(item, true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 用户消息气泡（右侧）
class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 300),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectionArea(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 助手文本气泡：Markdown 渲染（标题/列表/粗体/链接/代码块，长按可选中复制）
class _TextBubble extends StatelessWidget {
  const _TextBubble({required this.text, required this.cache});

  final String text;
  final ConversationMarkdownCache cache;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ConversationMarkdown(
          text: text,
          cache: cache,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(fontSize: 15, height: 1.4),
            listBullet: const TextStyle(fontSize: 15, height: 1.4),
            h1: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
            h2: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
            h3: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              height: 1.3,
            ),
            code: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              backgroundColor: isDark
                  ? Colors.grey.shade800
                  : Colors.grey.shade200,
            ),
            codeblockDecoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E1E28) : const Color(0xFFF0F1F5),
              borderRadius: BorderRadius.circular(8),
            ),
            codeblockPadding: const EdgeInsets.all(10),
            blockquoteDecoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: Colors.grey.shade400, width: 3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 思考过程气泡（灰色斜体）
class _ThoughtBubble extends StatelessWidget {
  const _ThoughtBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontStyle: FontStyle.italic,
            color: Colors.grey.shade700,
          ),
        ),
      ),
    );
  }
}

/// 工具执行行
class _ToolLine extends StatelessWidget {
  const _ToolLine({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// 回合结束行
class _TurnLine extends StatelessWidget {
  const _TurnLine({required this.ok, this.error});

  final bool ok;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            size: 16,
            color: ok ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              ok ? AppL10n.i.taskDone : AppL10n.i.taskFailed(error),
              style: TextStyle(
                fontSize: 13,
                color: ok ? Colors.green : Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// “正在思考…”等待指示行（回合运行中挂在消息列表末尾，回合结束即消失）
class _ThinkingLine extends StatelessWidget {
  const _ThinkingLine();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 13,
            height: 13,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            AppL10n.i.thinking,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

/// 流式打字机气泡（2026-10-28）：session.stream 的 text-delta 增量到达时
/// 挂在消息列表末尾实时展示；durable 的 assistant/message 落定后清空，
/// 由正常 Markdown 气泡接管。流式期间用纯 Text（每帧重建 Markdown 开销大）。
class _StreamingBubble extends StatelessWidget {
  const _StreamingBubble({required this.text, this.running = true});

  final bool running;

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 320),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primaryContainer
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          running ? '$text ▍' : text,
          style: const TextStyle(fontSize: 15, height: 1.4),
        ),
      ),
    );
  }
}

/// 输入栏上方的模型选择行：显示当前选中模型，点开底部弹层切换。
/// 选中项随每条 prompt 一起发送（session.prompt.modelId）：
/// - 新会话按所选模型创建；已有会话由 agent 侧尽力切换（当前宿主无
///   per-session 切换 API 时保持原模型，不阻塞发送）。
/// - 未选择（null）= 跟随宿主默认模型（电脑端 dsh 的“默认模型”设置）。
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.state});

  final AppState state;

  Future<void> _pick(BuildContext context) async {
    final models = state.models;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                AppL10n.i.pickModel,
                style: Theme.of(ctx).textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            // 「跟随默认」：清空 App 侧选择，回落宿主默认模型
            ListTile(
              dense: true,
              leading: const Icon(Icons.auto_awesome, size: 18),
              title: Text(
                AppL10n.i.followDesktopDefault,
                style: const TextStyle(fontSize: 14),
              ),
              trailing: (state.selectedModelId == null)
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () => Navigator.pop(ctx, ''),
            ),
            if (models.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                child: Text(
                  AppL10n.i.noModelsHint,
                  style: const TextStyle(color: Colors.grey, fontSize: 13),
                ),
              )
            else
              for (final m in models)
                ListTile(
                  dense: true,
                  title: Text(
                    (m['id'] ?? '').toString(),
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: (m['provider']?.toString().isNotEmpty ?? false)
                      ? Text(
                          m['provider'].toString(),
                          style: const TextStyle(fontSize: 11),
                        )
                      : null,
                  trailing:
                      (state.selectedModelId != null &&
                          state.selectedModelId == m['id'].toString())
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.pop(ctx, m['id']?.toString()),
                ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (selected == null) return; // 用户取消
    state.setSelectedModel(selected); // '' → null（跟随默认）
  }

  @override
  Widget build(BuildContext context) {
    final mid = state.selectedModelId;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pick(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tune,
              size: 14,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                (mid == null || mid.isEmpty)
                    ? AppL10n.i.followDesktopDefault
                    : mid,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            Icon(
              Icons.arrow_drop_down,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }
}

/// 待发送附件条：横向 chips（名字 + 进度条 / 就绪态），可单个移除。
/// 无附件时不占位。
class _AttachmentStrip extends StatelessWidget {
  const _AttachmentStrip({required this.state, required this.onRemoved});

  final AppState state;
  final ValueChanged<PendingAttachment> onRemoved;

  @override
  Widget build(BuildContext context) {
    final atts = state.pendingAttachments;
    if (atts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final a in atts)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
              child: InputChip(
                visualDensity: VisualDensity.compact,
                avatar: Icon(
                  a.kind == 'upload'
                      ? Icons.upload_file
                      : a.kind == 'file'
                      ? Icons.description_outlined
                      : Icons.link,
                  size: 16,
                ),
                label: Text(
                  a.progress != null
                      ? '${a.name} ${(a.progress! * 100).toStringAsFixed(0)}%'
                      : a.name,
                  style: const TextStyle(fontSize: 12),
                ),
                onDeleted: a.progress == null
                    ? () {
                        state.removeAttachment(a);
                        onRemoved(a);
                      }
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// 仅按需获取桌面工作区名称，不枚举项目文件。
class _ProjectPickerDialog extends StatefulWidget {
  const _ProjectPickerDialog({required this.state});
  final AppState state;
  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  late Future<List<ProjectEntry>> _future;
  @override
  void initState() {
    super.initState();
    _future = widget.state.listProjects();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(AppL10n.i.selectProject),
    content: SizedBox(
      width: 360,
      height: 320,
      child: Column(
        children: [
          Text(AppL10n.i.selectProjectHint),
          const SizedBox(height: 12),
          Expanded(
            child: FutureBuilder<List<ProjectEntry>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(AppL10n.i.projectsLoadFailed),
                      TextButton(
                        onPressed: () => setState(() {
                          _future = widget.state.listProjects();
                        }),
                        child: const Icon(Icons.refresh),
                      ),
                    ],
                  );
                }
                final projects = snapshot.data ?? [];
                if (projects.isEmpty)
                  return Center(child: Text(AppL10n.i.noProjects));
                return ListView(
                  children: [
                    for (final project in projects)
                      ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: Text(project.title),
                        onTap: () => Navigator.pop(context, project),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(AppL10n.i.cancel),
      ),
    ],
  );
}

class _ChangesPage extends StatelessWidget {
  const _ChangesPage({required this.entries});

  final List<ChangeEntry> entries;

  String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          AppL10n.i.changesTitle,
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: entries.isEmpty
          ? Center(
              child: Text(
                AppL10n.i.noChanges,
                style: const TextStyle(color: Colors.grey),
              ),
            )
          : ListView.separated(
              itemCount: entries.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = entries[i];
                final lines = diffLines(e.oldText, e.newText);
                final added = lines.where((l) => l.type == 'added').length;
                final removed = lines.where((l) => l.type == 'removed').length;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    e.isCreate ? Icons.post_add_outlined : Icons.edit_outlined,
                    color: e.isCreate ? Colors.green : Colors.orange,
                  ),
                  title: Text(
                    _basename(e.path),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    '${e.path} · ${e.isCreate ? AppL10n.i.newFileTag : AppL10n.i.modifiedTag} · +$added -$removed',
                    style: const TextStyle(fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => _FileDiffPage(entry: e),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// 单文件 diff 视图：行级渲染（added 绿底 / removed 红底 / same 灰字）
class _FileDiffPage extends StatelessWidget {
  const _FileDiffPage({required this.entry});

  final ChangeEntry entry;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final lines = diffLines(entry.oldText, entry.newText);
    final added = lines.where((l) => l.type == 'added').length;
    final removed = lines.where((l) => l.type == 'removed').length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          entry.path.split(RegExp(r'[\\/]')).last,
          style: const TextStyle(fontSize: 16, fontFamily: 'monospace'),
        ),
      ),
      body: Column(
        children: [
          Material(
            color: isDark ? Colors.blueGrey.shade900 : Colors.blueGrey.shade50,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: Text(
                  '${entry.path} · ${entry.isCreate ? AppL10n.i.newFileTag : AppL10n.i.modifiedTag} · +$added -$removed',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (context, i) {
                final l = lines[i];
                final bg = switch (l.type) {
                  'added' => Colors.green.withValues(alpha: 0.12),
                  'removed' => Colors.red.withValues(alpha: 0.12),
                  _ => Colors.transparent,
                };
                final fg = switch (l.type) {
                  'added' =>
                    isDark ? Colors.greenAccent : Colors.green.shade800,
                  'removed' => isDark ? Colors.redAccent : Colors.red.shade800,
                  _ => isDark ? Colors.white38 : Colors.black38,
                };
                final prefix = switch (l.type) {
                  'added' => '+',
                  'removed' => '-',
                  _ => ' ',
                };
                return Container(
                  color: bg,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 16,
                        child: Text(
                          prefix,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                            color: fg,
                          ),
                        ),
                      ),
                      Expanded(
                        child: SelectableText(
                          l.text.isEmpty ? ' ' : l.text,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.4,
                            color: fg,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

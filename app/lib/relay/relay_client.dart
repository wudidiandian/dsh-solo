/// 手机端 ↔ VPS relay 的 WebSocket 客户端。
///
/// 职责（设计文档 §6）：
/// 1. 连接后发送 hello.mobile 握手，hello.error 视为致命错误停止重连
/// 2. 断线自动重连（指数退避 + 抖动）
/// 3. rpc() 按 reqId 关联 rpc.response，超时抛 TimeoutException
/// 4. requestSync() 在重连后按 lastSeqId 请求差量补发
import 'dart:async';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../protocol/envelope.dart';
import 'e2ee.dart';

/// relay 连接状态
enum RelayStatus { idle, connecting, open, closed, fatal }

/// WebSocket 客户端（hello.mobile 角色）
class RelayClient {
  RelayClient({
    required this.url,
    required this.deviceToken,
    this.encryptionKey,
    this.allowUnencryptedForTests = false,
    this.baseBackoffMs = 500,
    this.maxBackoffMs = 15000,
  });

  final String url;
  final String deviceToken;
  final String? encryptionKey;
  final bool allowUnencryptedForTests;
  SecureMobile? _secure;
  bool _encryptionReady = false;
  Timer? _handshakeTimer;
  Future<void> _incoming = Future.value(), _outgoing = Future.value();
  final int baseBackoffMs;
  final int maxBackoffMs;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _started = false;
  int _generation = 0;
  final Map<String, Completer<Envelope>> _rpcWaiters = {};
  final List<Completer<void>> _openWaiters = [];

  RelayStatus status = RelayStatus.idle;
  String? lastError;

  /// 状态回调（连接 / 断开 / 鉴权失败）
  void Function(RelayStatus status, String? detail)? onStatus;

  /// 业务信封回调（hello.ok 之后的所有下行报文）
  void Function(Envelope env)? onEnvelope;

  /// 每次握手成功（hello.ok）回调一次，用于触发断点续传
  void Function()? onHandshakeOk;

  bool get isOpen => status == RelayStatus.open;
  bool get isEndToEndEncrypted => isOpen && _encryptionReady;

  /// 等待连接就绪：已 open 立即返回；断线中等待自动重连成功（或超时抛错）。
  /// 鉴权失败（fatal）立即抛错，不等待。
  Future<void> ensureOpen({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (isOpen) return;
    if (status == RelayStatus.fatal) {
      throw StateError('relay auth failed: ${lastError ?? 'token rejected'}');
    }
    if (!_started) start();
    final c = Completer<void>();
    _openWaiters.add(c);
    final timer = Timer(timeout, () {
      if (!c.isCompleted) c.completeError(StateError('relay not connected'));
    });
    try {
      await c.future;
    } finally {
      timer.cancel();
      _openWaiters.remove(c);
    }
  }

  /// 开始连接（重复调用无效；stop 后可再次 start）
  void start() {
    if (_started) return;
    _started = true;
    _connect();
  }

  /// 停止连接并取消自动重连
  void stop() {
    _generation++;
    _handshakeTimer?.cancel();
    _secure = null;
    _encryptionReady = false;
    _started = false;
    _retry?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _failAllWaiters('client stopped');
    _failOpenWaiters(StateError('client stopped'));
    status = RelayStatus.idle;
    _setStatus(RelayStatus.idle, null);
  }

  /// 发送一个信封（仅在 open 状态下有意义）
  void send(Envelope env) {
    if (allowUnencryptedForTests && _secure == null) {
      _channel?.sink.add(encodeEnvelope(env));
      return;
    }
    if (!_encryptionReady)
      throw StateError('Encrypted desktop connection is not ready');
    _sendEncrypted(env);
  }

  void _sendEncrypted(Envelope env) {
    final generation = _generation;
    final session = _secure?.session;
    if (session == null) throw StateError('No encrypted desktop session');
    _outgoing = _outgoing
        .then((_) async {
          if (generation != _generation) return;
          final packet = await session.seal(env);
          if (generation != _generation) return;
          _channel?.sink.add(
            encodeEnvelope(
              makeEnvelope('e2ee.data', packet, {'peerId': session.id}),
            ),
          );
        })
        .catchError((Object _) {
          if (generation == _generation)
            _encryptionFailure('Encrypted message could not be sent');
        });
  }

  void _encryptionFailure(String detail) {
    _handshakeTimer?.cancel();
    _started = false;
    _encryptionReady = false;
    _secure = null;
    _setStatus(RelayStatus.fatal, detail);
    _failAllWaiters(detail);
    _failOpenWaiters(StateError(detail));
    try {
      _channel?.sink.close();
    } catch (_) {}
  }

  /// 发送 cmd.dispatch 并等待定向 rpc.response
  Future<Envelope> rpc(
    String action,
    Map<String, Object?> data, {
    String? sessionId,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!isOpen) throw StateError('relay not connected');
    final reqId = newId();
    final completer = Completer<Envelope>();
    _rpcWaiters[reqId] = completer;
    send(
      makeEnvelope(
        MsgType.cmdDispatch,
        {'action': action, 'data': data},
        {'reqId': reqId, if (sessionId != null) 'sessionId': sessionId},
      ),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _rpcWaiters.remove(reqId);
        throw TimeoutException('rpc $action timeout');
      },
    );
  }

  /// 断线重连后请求补发某个会话的差量事件
  void requestSync(String sessionId, int lastSeqId) {
    if (allowUnencryptedForTests && _secure == null) {
      send(
        makeEnvelope(MsgType.syncRequest, {
          'sessionId': sessionId,
          'lastSeqId': lastSeqId,
        }),
      );
      return;
    }
    unawaited(
      rpc('session.history', {
            'sessionId': sessionId,
            'sinceSeqId': lastSeqId,
          }, sessionId: sessionId)
          .then((response) {
            final result = response.payloadMap['result'];
            if (response.payloadMap['ok'] != true ||
                result is! Map ||
                result['events'] is! List)
              return;
            onEnvelope?.call(
              makeEnvelope(
                MsgType.syncCatchup,
                {
                  'sessionId': sessionId,
                  'fromSeqId': lastSeqId,
                  'gap': false,
                  // session.history returns event payloads, whereas sync.catchup
                  // carries envelopes. Preserve session/sequence when adapting.
                  'events': [
                    for (final raw in result['events'] as List)
                      if (raw is Map)
                        Envelope(
                          type: MsgType.sessionEvent,
                          sessionId: sessionId,
                          seqId: (raw['seqId'] as num?)?.toInt(),
                          payload: Map<String, dynamic>.from(raw),
                        ).toJson(),
                  ],
                },
                {'sessionId': sessionId},
              ),
            );
          })
          .catchError((Object _) {
            /* Reconnect/history refresh retries on the next connection. */
          }),
    );
  }

  // ---------------------------------------------------------------------------

  void _setStatus(RelayStatus s, String? detail) {
    status = s;
    lastError = detail;
    onStatus?.call(s, detail);
  }

  Future<void> _connect() async {
    if (!_started) return;
    final generation = ++_generation;
    _handshakeTimer?.cancel();
    _encryptionReady = false;
    _secure = null;
    _incoming = Future.value();
    _outgoing = Future.value();
    if (encryptionKey == null || encryptionKey!.isEmpty) {
      if (!allowUnencryptedForTests) {
        _encryptionFailure(
          '请重新扫描新版插件二维码，或粘贴完整加密配对码 / Scan the updated plugin QR code',
        );
        return;
      }
    } else {
      try {
        _secure = SecureMobile(deviceToken, encryptionKey!);
      } catch (_) {
        _encryptionFailure(
          'Invalid encryption pairing key; scan the desktop QR code again',
        );
        return;
      }
    }
    _setStatus(RelayStatus.connecting, null);
    WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      _scheduleRetry('invalid url: $e');
      return;
    }
    try {
      await ch.ready;
    } catch (e) {
      if (_started && generation == _generation)
        _scheduleRetry('connect failed: $e');
      return;
    }
    if (!_started || generation != _generation) {
      try {
        await ch.sink.close();
      } catch (_) {}
      return;
    }
    _channel = ch;
    _attempt = 0;
    // 心跳保活：底层 WebSocket ping 帧（移动端），防止锁屏/切网后 TCP 半开连接
    // （半开时 App 看似在线实际已死，发消息/上传全部黑洞）。relay 的 ws 库自动回 pong。
    try {
      (ch as dynamic).websocket.pingInterval = const Duration(seconds: 25);
    } catch (_) {
      /* web 平台无此属性，忽略 */
    }
    // 握手：hello.mobile
    ch.sink.add(
      encodeEnvelope(
        makeEnvelope(MsgType.helloMobile, {
          'deviceToken': deviceToken,
          'deviceInfo': 'flutter-mobile',
          if (_secure != null) 'e2ee': 1,
          if (_secure != null) 'secureId': _secure!.id,
        }),
      ),
    );
    bool current() =>
        _started && generation == _generation && identical(_channel, ch);
    _sub = ch.stream.listen(
      (raw) {
        if (current()) {
          _incoming = _incoming
              .then((_) async {
                if (current()) await _onData(raw, generation);
              })
              .catchError((Object _) {
                if (current())
                  _encryptionFailure(
                    'Encrypted connection verification failed; please pair again',
                  );
              });
        }
      },
      onDone: () {
        if (current()) _onDone();
      },
      onError: (Object e) {
        if (current()) _onDone();
      },
      cancelOnError: true,
    );
  }

  Future<void> _onData(dynamic raw, int generation) async {
    if (raw is! String) return;
    if (raw.length > 6 * 1024 * 1024)
      throw StateError('Encrypted message exceeds limit');
    final env = tryDecodeEnvelope(raw);
    if (env == null) return;
    final secure = _secure;
    if (secure == null) {
      if (allowUnencryptedForTests) _deliver(env);
      return;
    }
    if (env.type == MsgType.helloError) {
      _deliver(env);
      return;
    }
    if (env.type == MsgType.helloOk) {
      if (env.payloadMap['e2ee'] != 1) {
        _encryptionFailure('中转服务需要升级才能使用端到端加密 / Relay upgrade required');
        return;
      }
      final hello = await secure.hello();
      if (generation != _generation || !_started) return;
      _channel?.sink.add(
        encodeEnvelope(
          makeEnvelope('e2ee.hello', hello, {'peerId': secure.id}),
        ),
      );
      _handshakeTimer = Timer(const Duration(seconds: 12), () {
        if (generation != _generation || _encryptionReady) return;
        try {
          _channel?.sink.close();
        } catch (_) {}
        _onDone();
      });
      return;
    }
    if (env.peerId != secure.id)
      throw StateError('Encrypted connection mismatch');
    if (env.type == 'e2ee.close') {
      if (env.payloadMap['reason'] == 'authentication-failed') {
        _encryptionFailure(
          '加密配对验证失败，请重新扫码 / Encryption authentication failed; pair again',
        );
        return;
      }
      try {
        _channel?.sink.close();
      } catch (_) {}
      _onDone();
      return;
    }
    if (env.type == 'e2ee.welcome') {
      await secure.accept(env.payloadMap.cast<String, dynamic>());
      if (generation != _generation || !_started) return;
      _sendEncrypted(makeEnvelope('e2ee.ready', {}));
      return;
    }
    if (env.type != 'e2ee.data' || secure.session == null)
      throw StateError('Unencrypted or unsupported desktop message');
    final inner = await secure.session!.open(
      env.payloadMap.cast<String, dynamic>(),
    );
    if (generation != _generation || !_started) return;
    if (!_encryptionReady) {
      if (inner.type != 'e2ee.ready')
        throw StateError('Missing desktop key confirmation');
      _encryptionReady = true;
      _handshakeTimer?.cancel();
      _deliver(makeEnvelope(MsgType.helloOk, {'e2ee': 1}));
    } else {
      if (![
        MsgType.agentSnapshot,
        MsgType.sessionEvent,
        MsgType.sessionStream,
        MsgType.rpcResponse,
      ].contains(inner.type))
        throw StateError('Unsupported encrypted message');
      _deliver(inner);
    }
  }

  void _deliver(Envelope env) {
    switch (env.type) {
      case MsgType.helloOk:
        _setStatus(RelayStatus.open, null);
        _flushOpenWaiters();
        onHandshakeOk?.call();
        break;
      case MsgType.helloError:
        // 鉴权失败：致命错误，停止重连
        _started = false;
        _setStatus(
          RelayStatus.fatal,
          env.payloadMap['reason']?.toString() ?? 'auth failed',
        );
        try {
          _channel?.sink.close();
        } catch (_) {}
        _failAllWaiters('auth failed');
        _failOpenWaiters(StateError('relay auth failed'));
        break;
      case MsgType.rpcResponse:
        final waiter = env.reqId == null ? null : _rpcWaiters.remove(env.reqId);
        if (waiter != null && !waiter.isCompleted) {
          waiter.complete(env);
        }
        break;
      default:
        break;
    }
    onEnvelope?.call(env);
  }

  void _onDone() {
    _handshakeTimer?.cancel();
    _secure = null;
    _encryptionReady = false;
    _sub?.cancel();
    _channel = null;
    _failAllWaiters('connection closed');
    if (!_started) return;
    _scheduleRetry('connection closed');
  }

  void _failAllWaiters(String reason) {
    for (final w in _rpcWaiters.values) {
      if (!w.isCompleted) w.completeError(StateError(reason));
    }
    _rpcWaiters.clear();
  }

  void _flushOpenWaiters() {
    for (final w in _openWaiters) {
      if (!w.isCompleted) w.complete();
    }
    _openWaiters.clear();
  }

  void _failOpenWaiters(Object error) {
    for (final w in _openWaiters) {
      if (!w.isCompleted) w.completeError(error);
    }
    _openWaiters.clear();
  }

  void _scheduleRetry(String reason) {
    if (!_started) return;
    _setStatus(RelayStatus.closed, reason);
    _retry?.cancel();
    // 指数退避 + 抖动：base .. max
    final exp = baseBackoffMs * (1 << _attempt.clamp(0, 5));
    final half = exp ~/ 2;
    var wait = half <= 0 ? baseBackoffMs : half + Random().nextInt(half + 1);
    if (wait > maxBackoffMs) wait = maxBackoffMs;
    _attempt++;
    _retry = Timer(Duration(milliseconds: wait), _connect);
  }
}

/// 测试共享工具：进程内可脚本化的假 relay 服务器。
import 'dart:async';
import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:dsh_solo/protocol/envelope.dart';

/// 假 relay 服务器
class FakeRelay {
  /// 每个新连接到达时的回调
  final void Function(FakeConn conn)? onConnection;

  final conns = <FakeConn>[];
  HttpServer? _server;

  FakeRelay({this.onConnection});

  String get url => 'ws://127.0.0.1:${_server!.port}/ws';
  int get port => _server!.port;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      final conn = FakeConn(IOWebSocketChannel(ws));
      conns.add(conn);
      onConnection?.call(conn);
    });
  }

  Future<void> stop() async {
    for (final c in List<FakeConn>.from(conns)) {
      await c.close();
    }
    await _server?.close(force: true);
  }
}

/// 假 relay 侧的单个连接
class FakeConn {
  FakeConn(this.ch) {
    sub = ch.stream.listen((raw) {
      final env = raw is String ? tryDecodeEnvelope(raw) : null;
      if (env != null) {
        received.add(env);
        onEnvelope?.call(env);
      }
    });
  }

  final WebSocketChannel ch;
  final received = <Envelope>[];
  late final StreamSubscription<dynamic> sub;

  /// 进站信封回调（模拟 relay 业务逻辑）
  void Function(Envelope env)? onEnvelope;

  void send(Envelope env) => ch.sink.add(encodeEnvelope(env));

  Future<void> close() async {
    await sub.cancel();
    await ch.sink.close().catchError((_) {});
  }
}

/// 轮询等待直到 [cond] 成立或超时（默认 5s）
Future<void> waitFor(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(interval);
  }
  if (!cond()) throw TimeoutException('waitFor condition not met within ${timeout.inMilliseconds}ms');
}

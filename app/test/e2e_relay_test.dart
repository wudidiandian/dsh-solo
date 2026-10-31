/// 跨语言端到端测试：Dart 手机端 ↔ 真实 Go relay 进程 ↔ 裸 WS 模拟 agent。
///
/// 验证链路（与 Go 侧 hub_test.go 的 9 步场景互补，这里从 Dart 客户端视角验证）：
/// 1. agent 握手 + 快照上报 → relay 缓存
/// 2. 手机 hello.mobile → relay 推缓存快照（秒开）
/// 3. 手机 cmd.dispatch(reqId) → relay 定向转发 agent → agent 回 rpc.response → 手机构造的 Future 完成
/// 4. agent 下发 session.event(seqId) → 手机实时收到
/// 5. 文件上传：file.offer/chunk → relay 字节限流透传 → 模拟 agent 落盘 → 手机拿到路径；
///    超限 offer 被 relay 硬拒绝（模拟破解客户端绕过 App 校验也拦得住）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';

import 'fake_relay.dart';

const relayPort = 18991;

/// 项目根目录（flutter test 的 CWD 是 app/，其父目录即 monorepo 根）
final projectRoot = Directory.current.parent.path;

Future<String?> locateGo() async {
  final candidates = <String>[
    if (Platform.isWindows) '$projectRoot\\.sdk\\go\\bin\\go.exe',
    if (Platform.isWindows) 'C:\\Program Files\\Go\\bin\\go.exe',
    'go',
  ];
  for (final c in candidates) {
    try {
      final r = await Process.run(c, ['version']);
      if (r.exitCode == 0) return c;
    } catch (_) {}
  }
  return null;
}

/// 轮询等待 HTTP 健康检查通过
Future<void> waitForHealth(String url, {Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    try {
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      if (res.statusCode == 200) return;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw TimeoutException('relay /healthz not ready: $url');
}

void main() {
  test('Dart 手机端 ↔ Go relay ↔ 模拟 agent 全链路', () async {
    final go = await locateGo();
    if (go == null) {
      // 本机无 Go 工具链时跳过（CI 环境例外）
      return;
    }

    // 1. 构建并启动真实 relay
    final relayExe = '$projectRoot/.generated/relay-e2e${Platform.isWindows ? '.exe' : ''}';
    await Directory('$projectRoot/.generated').create(recursive: true);
    final build = await Process.run(
      go,
      ['build', '-C', '$projectRoot/server', '-o', relayExe, './cmd/relay'],
    );
    expect(build.exitCode, 0, reason: 'go build failed: ${build.stderr}');

    final relayProc = await Process.start(
      relayExe,
      ['-addr', '127.0.0.1:$relayPort'],
    );
    var relayStderr = '';
    relayProc.stderr.transform(utf8.decoder).listen((d) {
      relayStderr += d;
    });

    try {
      await waitForHealth('http://127.0.0.1:$relayPort/healthz');

      // 2. 模拟 agent：裸 WS 连接 + 握手 + 快照
      final agentCh = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$relayPort/ws'));
      await agentCh.ready;
      final agentInbox = <Envelope>[];
      agentCh.stream.listen((raw) {
        final env = raw is String ? tryDecodeEnvelope(raw) : null;
        if (env != null) agentInbox.add(env);
      });
      agentCh.sink.add(encodeEnvelope(makeEnvelope(MsgType.helloAgent, {'deviceToken': 'e2e-tok'})));

      // 等待 agent 握手确认
      final helloOk = Completer<void>();
      final timer = Timer.periodic(const Duration(milliseconds: 20), (t) {
        if (agentInbox.any((e) => e.type == MsgType.helloOk)) {
          t.cancel();
          helloOk.complete();
        }
      });
      await helloOk.future.timeout(const Duration(seconds: 5));
      timer.cancel();

      agentCh.sink.add(encodeEnvelope(makeEnvelope(MsgType.agentSnapshot, {
        'models': [
          {'id': 'deepseek-v3'},
        ],
        'sessions': [],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      })));

      // 3. 手机端（被测的 RelayClient）连接
      final client = RelayClient(url: 'ws://127.0.0.1:$relayPort/ws', deviceToken: 'e2e-tok');
      final snapshots = <Envelope>[];
      final events = <Envelope>[];
      client.onEnvelope = (env) {
        if (env.type == MsgType.agentSnapshot) snapshots.add(env);
        if (env.type == MsgType.sessionEvent) events.add(env);
      };
      client.start();

      // 秒开：连上就应收到 relay 缓存的快照
      final gotSnapshot = Completer<void>();
      final snapTimer = Timer.periodic(const Duration(milliseconds: 20), (t) {
        if (snapshots.isNotEmpty) {
          t.cancel();
          gotSnapshot.complete();
        }
      });
      await gotSnapshot.future.timeout(const Duration(seconds: 5));
      snapTimer.cancel();
      expect(
        (snapshots.first.payloadMap['models'] as List).first['id'],
        'deepseek-v3',
        reason: '手机连接后应立即收到 relay 缓存的快照',
      );

      // 4. 手机 RPC：cmd.dispatch → relay 转发 agent → agent 回包
      final respFuture = client.rpc('session.prompt', {'prompt': 'e2e-hello'}, sessionId: 's1');
      // agent 侧应收到 cmd.dispatch
      await waitFor(() => agentInbox.any((e) => e.type == MsgType.cmdDispatch));
      final dispatch = agentInbox.firstWhere((e) => e.type == MsgType.cmdDispatch);
      expect((dispatch.payload as Map)['action'], 'session.prompt');
      expect(dispatch.reqId, isNotNull);
      // agent 按 reqId 回包
      agentCh.sink.add(encodeEnvelope(makeEnvelope(
        MsgType.rpcResponse,
        {'ok': true, 'result': {'sessionId': 's1'}},
        {'reqId': dispatch.reqId},
      )));
      final resp = await respFuture;
      expect(resp.payloadMap['ok'], isTrue);
      expect((resp.payloadMap['result'] as Map)['sessionId'], 's1');

      // 5. agent 下发事件 → 手机实时收到
      agentCh.sink.add(encodeEnvelope(makeEnvelope(
        MsgType.sessionEvent,
        {'kind': 'text.delta', 'text': '跨语言 OK'},
        {'sessionId': 's1', 'seqId': 1, 'pushLevel': 'none'},
      )));
      await waitFor(() => events.isNotEmpty);
      expect((events.first.payload as Map)['text'], '跨语言 OK');
      expect(events.first.seqId, 1);

      client.stop();
      await agentCh.sink.close();
    } catch (e) {
      fail('E2E failed: $e\nrelay stderr: $relayStderr');
    } finally {
      relayProc.kill();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Dart 手机端文件上传 ↔ Go relay 限流转发 ↔ 模拟 agent 落盘', () async {
    final go = await locateGo();
    if (go == null) return;

    final relayExe = '$projectRoot/.generated/relay-e2e${Platform.isWindows ? '.exe' : ''}';
    await Directory('$projectRoot/.generated').create(recursive: true);
    final build = await Process.run(
      go,
      ['build', '-C', '$projectRoot/server', '-o', relayExe, './cmd/relay'],
    );
    expect(build.exitCode, 0, reason: 'go build failed: ${build.stderr}');

    final relayProc = await Process.start(relayExe, ['-addr', '127.0.0.1:$relayPort']);
    var relayStderr = '';
    relayProc.stderr.transform(utf8.decoder).listen((d) => relayStderr += d);

    try {
      await waitForHealth('http://127.0.0.1:$relayPort/healthz');

      // 模拟 agent：收 file.offer 确认；收 file.chunk 缓存并逐块 ack；
      // 收齐后写临时文件，最后一块的 ack 带回落盘路径
      final agentCh = IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:$relayPort/ws'));
      await agentCh.ready;
      final offers = <Map<dynamic, dynamic>>[];
      final received = <int, List<int>>{};
      var declaredChunks = 0;
      final uploadDone = Completer<String>();
      agentCh.stream.listen((raw) {
        final env = raw is String ? tryDecodeEnvelope(raw) : null;
        if (env == null || env.type != MsgType.cmdDispatch) return;
        final p = env.payload as Map;
        final action = p['action'];
        final data = p['data'] as Map;
        if (action == 'device.token.get') {
          agentCh.sink.add(encodeEnvelope(makeEnvelope(MsgType.rpcResponse,
            {'ok': true, 'result': {'token': 'e2e-up'}}, {'reqId': env.reqId})));
        } else if (action == 'file.offer') {
          offers.add(data);
          declaredChunks = data['chunks'] as int;
          agentCh.sink.add(encodeEnvelope(makeEnvelope(
            MsgType.rpcResponse,
            {'ok': true, 'result': {'transferId': data['transferId'], 'received': 0, 'chunks': declaredChunks}},
            {'reqId': env.reqId},
          )));
        } else if (action == 'file.chunk') {
          final idx = data['index'] as int;
          received[idx] = base64Decode(data['data'] as String);
          final all = received.length == declaredChunks;
          // 最后一块：模拟 agent 落盘并回传路径
          final result = all
              ? <dynamic, dynamic>{'transferId': data['transferId'], 'done': true, 'size': received.values.fold<int>(0, (a, b) => a + b.length)}
              : <dynamic, dynamic>{'transferId': data['transferId'], 'index': idx, 'received': received.length, 'chunks': declaredChunks};
          if (all) {
            final file = <int>[];
            for (var i = 0; i < declaredChunks; i++) {
              file.addAll(received[i]!);
            }
            final path = '$projectRoot/.generated/e2e-upload-${DateTime.now().millisecondsSinceEpoch}.bin';
            File(path).writeAsBytesSync(file);
            result['done'] = true;
            result['path'] = path;
            result['name'] = data['transferId'];
          }
          agentCh.sink.add(encodeEnvelope(makeEnvelope(
            MsgType.rpcResponse,
            {'ok': true, 'result': result},
            {'reqId': env.reqId},
          )));
          if (all) uploadDone.complete(result['path'] as String);
        }
      });
      agentCh.sink.add(encodeEnvelope(makeEnvelope(MsgType.helloAgent, {'deviceToken': 'e2e-up'})));
      // 等握手完成
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // 手机端用被测的 AppState 走真实上传路径
      final state = AppState()..connect(RelayClient(url: 'ws://127.0.0.1:$relayPort/ws', deviceToken: 'e2e-up'));
      await waitFor(() => state.relayStatus == RelayStatus.open);

      // ---- 场景 A：绕过 App 校验的超限 offer（模拟破解客户端）→ relay 硬拒绝 ----
      final rejected = await state.client!.rpc(CmdAction.fileOffer, {
        'transferId': 'evil-1',
        'name': 'evil.bin',
        'size': (10 << 20) + 1, // 10MB + 1 字节，超过 relay 默认 max-upload
        'chunks': 44,
      });
      expect(rejected.payloadMap['ok'], isFalse, reason: '超限 offer 应被 relay 拒绝');
      expect(rejected.payloadMap['error'].toString(), contains('exceeds limit'));
      expect(offers, isEmpty, reason: '被拒的 offer 不应转发到 agent');

      // ---- 场景 B：正常分块上传（600KB = 3 块）→ relay 限流内透传 → 落盘一致 ----
      final payload = Uint8List(600 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = i % 251; // 伪随机但确定的内容
      }
      final path = await state.uploadBytes(payload, name: 'e2e-photo.jpg', mime: 'image/jpeg');
      final landedPath = await uploadDone.future.timeout(const Duration(seconds: 10));
      expect(landedPath, path, reason: 'agent 回传路径应与 uploadBytes 返回一致');
      final landed = File(landedPath);
      expect(landed.existsSync(), isTrue, reason: 'agent 侧文件应已落盘');
      expect(landed.lengthSync(), payload.length, reason: '落盘大小应与上传一致');
      // 抽样校验内容一致
      final diskBytes = landed.readAsBytesSync();
      expect(diskBytes[0], payload[0]);
      expect(diskBytes[diskBytes.length - 1], payload[payload.length - 1]);
      expect(diskBytes[diskBytes.length ~/ 2], payload[payload.length ~/ 2]);
      // App 状态：上传条目应为就绪态（有 path、无进行中进度）
      final att = state.pendingAttachments.single;
      expect(att.path, path);
      expect(att.progress, isNull);
      // 清理落盘产物
      landed.deleteSync();

      state.client!.stop();
      await agentCh.sink.close();
    } catch (e) {
      fail('Upload E2E failed: $e\nrelay stderr: $relayStderr');
    } finally {
      relayProc.kill();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

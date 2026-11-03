import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/e2ee.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/pair_scan_page.dart';

import 'e2e_relay_test.dart' show locateGo, waitForHealth;
import 'fake_relay.dart' show waitFor, FakeRelay;

final root = Directory.current.parent.path;
final key = base64UrlEncode(List.filled(32, 7)).replaceAll('=', '');
const token = 'secure-test-token';

void main() {
  test('new QR/manual pairing contains an independent key and rejects legacy or malformed codes', () {
    final qr = Uri(
      scheme: 'dshsolo',
      host: 'pair',
      queryParameters: {
        'relay': 'wss://example.invalid/ws',
        'token': token,
        'key': key,
        'e2ee': '1',
      },
    ).toString();
    expect(parsePairUri(qr)?.encryptionKey, key);
    final manual =
        'dshpair1.${base64UrlEncode(utf8.encode(jsonEncode({'relay': 'wss://example.invalid/ws', 'token': token, 'key': key}))).replaceAll('=', '')}';
    expect(parsePairUri(manual), parsePairUri(qr));
    expect(
      parsePairUri(
        'dshsolo://pair?relay=wss://example.invalid/ws&token=$token',
      ),
      isNull,
    );
    expect(parsePairUri('$qr-bad'), isNull);
    expect(parsePairUri('dshpair1.invalid'), isNull);
  });
  test('Dart/Node X25519, HKDF and AES-GCM interoperate; corrupted and replayed messages fail', () async {
    final node = await Process.start('node', [
      '$root/scripts/test/e2ee-peer.mjs',
    ]);
    final lines = StreamIterator(
      node.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(() async {
      await node.stdin.close();
      node.kill();
      await lines.cancel();
    });
    Future<Map<String, dynamic>> request(Map<String, Object?> value) async {
      node.stdin.writeln(jsonEncode(value));
      expect(
        await lines.moveNext().timeout(const Duration(seconds: 10)),
        isTrue,
      );
      return (jsonDecode(lines.current) as Map).cast<String, dynamic>();
    }

    final mobile = SecureMobile(token, key);
    final welcome = await request({
      'op': 'hello',
      'hello': await mobile.hello(),
    });
    final session = await mobile.accept(welcome);
    final command = makeEnvelope(
      MsgType.cmdDispatch,
      {
        'action': 'session.prompt',
        'data': {'prompt': '跨语言秘密🚀'},
      },
      {'reqId': 'test-request'},
    );
    final packet = await session.seal(command);
    expect(jsonEncode(packet), isNot(contains('跨语言秘密')));
    final answer = await request({'op': 'roundtrip', 'packet': packet});
    expect(answer['plain'], command.toJson());
    final reply = (answer['packet'] as Map).cast<String, dynamic>();
    final badBytes = base64Decode(reply['ciphertext'] as String);
    badBytes[0] ^= 1;
    await expectLater(
      session.open({...reply, 'ciphertext': base64Encode(badBytes)}),
      throwsA(anything),
    );
    final opened = await session.open(reply);
    expect(opened.reqId, 'test-request');
    expect(opened.payloadMap['ok'], isTrue);
    await expectLater(session.open(reply), throwsA(isA<StateError>()));
    final replay = await request({'op': 'roundtrip', 'packet': packet});
    expect(replay['error'], isNotNull);
  });
  test('missing pairing key never opens a plaintext WebSocket', () async {
    final client = RelayClient(url: 'ws://127.0.0.1:1/ws', deviceToken: token);
    client.start();
    await waitFor(() => client.status == RelayStatus.fatal);
    expect(client.lastError, contains('二维码'));
    client.stop();
  });
  test('an old relay cannot downgrade encrypted pairing or supply a plaintext snapshot', () async {
    final relay = FakeRelay(
      onConnection: (connection) {
        connection.onEnvelope = (env) {
          if (env.type == MsgType.helloMobile) {
            connection.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
            connection.send(
              makeEnvelope(MsgType.agentSnapshot, {
                'sessions': [
                  {'id': 'forged', 'title': 'FORGED_PLAINTEXT'},
                ],
              }),
            );
          }
        };
      },
    );
    await relay.start();
    final state = AppState();
    addTearDown(() async {
      state.dispose();
      await relay.stop();
    });
    state.connect(
      RelayClient(url: relay.url, deviceToken: token, encryptionKey: key),
    );
    await waitFor(() => state.relayStatus == RelayStatus.fatal);
    expect(state.isDesktopConnected, isFalse);
    expect(state.sessions, isEmpty);
  });

  test('real App ↔ Go relay ↔ Node plugin encrypts snapshots, commands, attachments, reconnection and multiple phones', () async {
    final go = await locateGo();
    expect(
      go,
      isNotNull,
      reason: 'Secure integration requires the Go toolchain',
    );
    final temporary = await Directory.systemTemp.createTemp(
      'dsh-encrypted-test-',
    );
    final relayExe =
        '${temporary.path}/relay${Platform.isWindows ? '.exe' : ''}';
    final build = await Process.run(go!, [
      'build',
      '-C',
      '$root/server',
      '-o',
      relayExe,
      './cmd/relay',
    ]);
    expect(build.exitCode, 0, reason: build.stderr.toString());
    final portSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = portSocket.port;
    await portSocket.close();
    final relay = await Process.start(relayExe, ['--addr', '127.0.0.1:$port']);
    relay.stdout.drain<void>();
    relay.stderr.drain<void>();
    addTearDown(() async {
      relay.kill();
      await relay.exitCode;
      await File(relayExe).delete();
      await temporary.delete();
    });
    await waitForHealth('http://127.0.0.1:$port/healthz');
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final frames = <String>[];
    final sockets = <WebSocket>[];
    proxy.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 426;
        await request.response.close();
        return;
      }
      final downstream = await WebSocketTransformer.upgrade(request);
      final upstream = await WebSocket.connect('ws://127.0.0.1:$port/ws');
      sockets.addAll([downstream, upstream]);
      downstream.listen((raw) {
        frames.add(raw.toString());
        upstream.add(raw);
      }, onDone: () => upstream.close());
      upstream.listen((raw) {
        frames.add(raw.toString());
        downstream.add(raw);
      }, onDone: () => downstream.close());
    });
    final url = 'ws://127.0.0.1:${proxy.port}/ws';
    final agent = await Process.start('node', [
      '$root/scripts/test/e2ee-peer.mjs',
      '--agent',
      url,
    ]);
    final agentOutput = StreamIterator(
      agent.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    final errors = StringBuffer();
    agent.stderr.transform(utf8.decoder).listen(errors.write);
    final states = <AppState>[];
    addTearDown(() async {
      for (final state in states) {
        state.dispose();
      }
      agent.stdin.writeln('stop');
      await agent.stdin.flush();
      try {
        await agent.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        agent.kill();
      }
      await agentOutput.cancel();
      for (final socket in sockets) {
        await socket.close();
      }
      await proxy.close(force: true);
    });
    expect(
      await agentOutput.moveNext().timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw StateError(errors.toString()),
      ),
      isTrue,
    );
    AppState phone({String? pairingKey, String routingToken = token}) {
      final state = AppState();
      states.add(state);
      state.connect(
        RelayClient(
          url: url,
          deviceToken: routingToken,
          encryptionKey: pairingKey ?? key,
          baseBackoffMs: 50,
        ),
      );
      return state;
    }

    final first = phone();
    await waitFor(
      () => first.isDesktopConnected,
      timeout: const Duration(seconds: 15),
    );
    expect(first.sessions.single.title, 'E2EE_CONTENT_SENTINEL');
    expect((await first.listProjects()).single.title, 'E2EE_PROJECT_SENTINEL');
    final prompt = await first.sendPrompt(
      'E2EE_PROMPT_SENTINEL',
      projectId: 'secret-project',
    );
    expect(prompt.payloadMap['ok'], isTrue);
    final statuses = <RelayStatus>[];
    final oldStatus = first.client!.onStatus;
    first.client!.onStatus = (status, detail) { statuses.add(status); oldStatus?.call(status, detail); };
    final beforeBurst = frames.length;
    agent.stdin.writeln('burst');
    expect(await agentOutput.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(jsonDecode(agentOutput.current)['burstComplete'], isTrue);
    await waitFor(() => first.eventsOf('created-session').any((e) => e.payloadMap['kind'] == 'turn/end'));
    expect(first.streamingTextOf('created-session'), isEmpty);
    expect(first.eventsOf('created-session').last.payloadMap['kind'], 'turn/end');
    expect(first.eventsOf('created-session').where((e) => e.payloadMap['kind'] == 'assistant/message').last.payloadMap['text'], '字🚀' * 2000);
    expect(statuses, isEmpty, reason: '2,000 host tokens must not interrupt the encrypted stream');
    expect(frames.length - beforeBurst, lessThan(80));
    final fileBytes = Uint8List(6 * 1024 * 1024);
    final marker = utf8.encode('E2EE_FILE_SENTINEL');
    fileBytes.setRange(0, marker.length, marker);
    final upload = await first.uploadBytes(
      fileBytes,
      name: 'E2EE_FILENAME_SENTINEL.txt',
      mime: 'text/plain',
    );
    expect(upload, isNotEmpty);
    expect(await File(upload).length(), fileBytes.length);
    expect(
      (await File(upload).readAsBytes()).sublist(0, marker.length),
      marker,
    );
    final second = phone();
    await waitFor(
      () => second.isDesktopConnected,
      timeout: const Duration(seconds: 15),
    );
    expect((await second.listProjects()).single.id, 'secret-project');
    final wrong = phone(
      pairingKey: base64UrlEncode(List.filled(32, 8)).replaceAll('=', ''),
    );
    await waitFor(() => wrong.client!.status == RelayStatus.fatal);
    expect(wrong.isDesktopConnected, isFalse);
    expect(wrong.sessions, isEmpty);
    first.client!.stop();
    agent.stdin.writeln('offline-completion');
    expect(await agentOutput.moveNext().timeout(const Duration(seconds: 10)), isTrue);
    expect(jsonDecode(agentOutput.current)['offlineComplete'], isTrue);
    first.client!.start();
    await waitFor(
      () => first.isDesktopConnected,
      timeout: const Duration(seconds: 15),
    );
    expect(
      (await first.fetchHistory('created-session')).payloadMap['ok'],
      isTrue,
    );
    await waitFor(() => first.eventsOf('created-session').any((e) => e.payloadMap['text'] == 'OFFLINE_FINAL_SENTINEL'));
    expect(first.eventsOf('created-session').last.payloadMap['kind'], 'turn/end');
    agent.stdin.writeln('rotate');
    expect(
      await agentOutput.moveNext().timeout(const Duration(seconds: 10)),
      isTrue,
    );
    final rotated = jsonDecode(agentOutput.current) as Map;
    await waitFor(
      () => !first.isDesktopConnected && !second.isDesktopConnected,
    );
    final rePaired = phone(
      pairingKey: rotated['key'] as String,
      routingToken: rotated['token'] as String,
    );
    await waitFor(
      () => rePaired.isDesktopConnected,
      timeout: const Duration(seconds: 15),
    );
    expect((await rePaired.listProjects()).single.id, 'secret-project');
    final visible = frames.join('\n');
    expect(visible, isNot(contains(rotated['key'])));
    for (final secret in [
      'E2EE_CONTENT_SENTINEL',
      'E2EE_PROJECT_SENTINEL',
      'E2EE_PROMPT_SENTINEL',
      'E2EE_FILE_SENTINEL',
      'E2EE_FILENAME_SENTINEL',
      key,
      'secret-project',
      'session.prompt',
      'file.chunk',
    ]) {
      expect(
        visible,
        isNot(contains(secret)),
        reason: 'Relay must not see $secret',
      );
    }
    expect(visible, contains('e2ee.data'));
    expect(
      visible,
      contains(token),
    ); // Only the separate routing token is visible to the relay.
  }, timeout: const Timeout(Duration(seconds: 90)));
}

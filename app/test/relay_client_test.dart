/// RelayClient 单元测试：进程内假 relay 验证握手 / RPC 关联 / 断线重连 / 续传。
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';

import 'fake_relay.dart';

void main() {
  group('RelayClient', () {
    test('握手成功进入 open 并收到快照', () async {
      final relay = FakeRelay(
        onConnection: (conn) {
          conn.onEnvelope = (env) {
            if (env.type == MsgType.helloMobile) {
              conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
              conn.send(makeEnvelope(MsgType.agentSnapshot, {
                'models': [
                  {'id': 'deepseek-v3'},
                ],
                'sessions': [],
                'timestamp': 1,
              }));
            }
          };
        },
      );
      await relay.start();

      final client = RelayClient(url: relay.url, deviceToken: 'test-phone');
      final snapshots = <Envelope>[];
      client.onEnvelope = (env) {
        if (env.type == MsgType.agentSnapshot) snapshots.add(env);
      };
      client.start();

      await waitFor(() => client.status == RelayStatus.open && snapshots.isNotEmpty);

      expect(client.status, RelayStatus.open);
      expect(snapshots, hasLength(1));
      expect((snapshots.first.payloadMap['models'] as List).first['id'], 'deepseek-v3');

      // 出站握手报文符合协议
      final hello = relay.conns.first.received.first;
      expect(hello.type, MsgType.helloMobile);
      expect(hello.payloadMap['deviceToken'], 'test-phone');
      expect(hello.v, protocolVersion);

      client.stop();
      await relay.stop();
    });

    test('rpc 按 reqId 关联回包', () async {
      final relay = FakeRelay(
        onConnection: (conn) {
          conn.onEnvelope = (env) {
            if (env.type == MsgType.helloMobile) {
              conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
            } else if (env.type == MsgType.cmdDispatch) {
              expect(env.payloadMap['action'], 'fs.list_dir');
              conn.send(makeEnvelope(
                MsgType.rpcResponse,
                {'ok': true, 'result': [
                  {'name': 'a.txt'},
                ]},
                {'reqId': env.reqId},
              ));
            }
          };
        },
      );
      await relay.start();

      final client = RelayClient(url: relay.url, deviceToken: 't');
      client.start();
      await waitFor(() => client.status == RelayStatus.open);

      final resp = await client.rpc('fs.list_dir', {'path': '/tmp'});
      expect(resp.payloadMap['ok'], isTrue);
      expect(resp.reqId, isNotNull);

      client.stop();
      await relay.stop();
    });

    test('断线自动重连 + onHandshakeOk 触发 + sync.request 发送', () async {
      var connCount = 0;
      final syncRequests = <Map<String, dynamic>>[];
      FakeConn? firstConn;
      final relay = FakeRelay(
        onConnection: (conn) {
          connCount++;
          if (connCount == 1) {
            firstConn = conn;
            // 第一条连接：只握手，不发快照
            conn.onEnvelope = (env) {
              if (env.type == MsgType.helloMobile) {
                conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
              }
            };
          } else {
            // 重连后的连接：正常握手 + 处理 sync.request
            conn.onEnvelope = (env) {
              if (env.type == MsgType.helloMobile) {
                conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
              } else if (env.type == MsgType.syncRequest) {
                syncRequests.add(env.payloadMap);
              }
            };
          }
        },
      );
      await relay.start();

      final client = RelayClient(
        url: relay.url,
        deviceToken: 't',
        baseBackoffMs: 20,
        maxBackoffMs: 100,
      );
      var handshakes = 0;
      client.onHandshakeOk = () => handshakes++;
      client.start();

      await waitFor(() => client.status == RelayStatus.open);

      // 服务端强制断开第一条连接
      await firstConn!.close();
      relay.conns.remove(firstConn);

      // 等待重连 + 二次握手
      await waitFor(() => connCount >= 2 && client.status == RelayStatus.open && handshakes >= 2);

      // 重连后按 lastSeqId 请求续传
      client.requestSync('sess-1', 42);
      await waitFor(() => syncRequests.isNotEmpty);
      expect(syncRequests.first['sessionId'], 'sess-1');
      expect(syncRequests.first['lastSeqId'], 42);

      client.stop();
      await relay.stop();
    });

    test('hello.error 致命：进入 fatal 且不再重连', () async {
      var connCount = 0;
      final relay = FakeRelay(
        onConnection: (conn) {
          connCount++;
          conn.onEnvelope = (env) {
            if (env.type == MsgType.helloMobile) {
              conn.send(makeEnvelope(MsgType.helloError, {'reason': 'bad token'}));
            }
          };
        },
      );
      await relay.start();

      final client = RelayClient(url: relay.url, deviceToken: 'bad', baseBackoffMs: 20);
      client.start();

      await waitFor(() => client.status == RelayStatus.fatal);
      expect(client.lastError, 'bad token');

      // fatal 后不应再发起新连接
      final countAfterFatal = connCount;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(connCount, countAfterFatal);
      expect(countAfterFatal, 1);

      client.stop();
      await relay.stop();
    });
  });
}

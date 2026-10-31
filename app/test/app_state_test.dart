/// AppState 测试：快照解析 / 事件去重与续传 / 审批提取 / 重连续传请求
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';

import 'fake_relay.dart';

Envelope event(String sid, int seq, Map<String, dynamic> payload) =>
    makeEnvelope(MsgType.sessionEvent, payload, {'sessionId': sid, 'seqId': seq});

void main() {
  group('AppState', () {
    test('快照解析：models / sessions 防御性处理', () {
      final state = AppState();
      state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {
        'models': [
          {'id': 'deepseek-v3'},
          'raw-string-model',
        ],
        'sessions': [
          {'id': 's1', 'title': '会话一', 'model': 'deepseek-v3'},
          'legacy-string',
        ],
        'timestamp': 1,
      }));

      expect(state.models, hasLength(2));
      expect(state.models.first['id'], 'deepseek-v3');
      expect(state.sessions.map((s) => s.id).toList(), ['s1', 'legacy-string']);
      expect(state.sessions.first.displayTitle, '会话一');
    });

    test('事件按 seqId 有序追加，乱序回退与重复报文被丢弃', () {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {'kind': 'text.delta', 'text': 'a'}));
      state.applyEnvelope(event('s1', 3, {'kind': 'text.delta', 'text': 'c'}));
      state.applyEnvelope(event('s1', 2, {'kind': 'text.delta', 'text': 'late'})); // 2 <= lastSeq(3)：丢弃
      state.applyEnvelope(event('s1', 3, {'kind': 'text.delta', 'text': 'dup'})); // 重复：丢弃
      state.applyEnvelope(event('s1', 4, {'kind': 'text.delta', 'text': 'd'})); // 正常追加

      expect(state.lastSeq['s1'], 4);
      expect(state.eventsOf('s1'), hasLength(3));
      expect(state.eventsOf('s1').map((e) => (e.payload as Map)['text']).toList(), ['a', 'c', 'd']);
    });

    test('approval_request 提取为待审批项', () {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {
        'kind': 'approval_request',
        'approvalId': 'ap-1',
        'toolName': 'bash',
        'summary': 'git push',
      }));

      expect(state.pendingApprovalCount, 1);
      final item = state.approvals['ap-1']!;
      expect(item.toolName, 'bash');
      expect(item.summary, 'git push');
      expect(item.sessionId, 's1');

      item.resolved = true;
      state.notifyListeners();
      expect(state.pendingApprovalCount, 0);
    });

    test('sync.catchup 补发事件并入，gap 标记进入 gapSessions', () {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {'kind': 'text.delta', 'text': 'a'}));

      state.applyEnvelope(makeEnvelope(MsgType.syncCatchup, {
        'sessionId': 's1',
        'fromSeqId': 1,
        'toSeqId': 4,
        'gap': true,
        'events': [
          event('s1', 2, {'kind': 'text.delta', 'text': 'b'}).toJson(),
          event('s1', 3, {'kind': 'turn.completed'}).toJson(),
        ],
      }));

      expect(state.gapSessions.contains('s1'), isTrue);
      expect(state.lastSeq['s1'], 3);
      expect(state.eventsOf('s1').map((e) => e.seqId).toList(), [1, 2, 3]);
    });

    test('onReconnected 对已知会话自动发起 sync.request', () async {
      final relay = FakeRelay(
        onConnection: (conn) {
          conn.onEnvelope = (env) {
            if (env.type == MsgType.helloMobile) {
              conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
            } else if (env.type == MsgType.cmdDispatch && env.payloadMap['action'] == 'device.token.get') {
              conn.send(makeEnvelope(MsgType.rpcResponse, {'ok': true, 'result': {'token': 't'}}, {'reqId': env.reqId}));
            }
          };
        },
      );
      await relay.start();

      final state = AppState();
      state.applyEnvelope(event('s1', 5, {'kind': 'text.delta', 'text': 'a'}));

      state.connect(RelayClient(url: relay.url, deviceToken: 't'));
      await waitFor(() => state.isDesktopConnected);

      // 模拟断线重连后的自动续传
      state.onReconnected();
      await waitFor(() => relay.conns.any((c) => c.received.any((e) => e.type == MsgType.syncRequest)));

      final sync = relay.conns
          .expand((c) => c.received)
          .firstWhere((e) => e.type == MsgType.syncRequest);
      expect(sync.payloadMap, {'sessionId': 's1', 'lastSeqId': 5});

      state.client?.stop();
      await relay.stop();
    });
  });
}

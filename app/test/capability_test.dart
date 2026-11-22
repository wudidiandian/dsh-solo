/// 能力协商测试：快照能力表解析 / 显式 false 才降级 / 旧插件向后兼容 / 模型选择提示
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/session_page.dart';

import 'fake_relay.dart';

class _OfflineState extends AppState {
  @override
  Future<Envelope> fetchHistory(String sessionId, {int? sinceSeqId}) async =>
      makeEnvelope(MsgType.rpcResponse, {
        'ok': true,
        'result': {'events': []},
      });
}

Envelope snapshot(Map<String, dynamic> extra) => makeEnvelope(
  MsgType.agentSnapshot,
  {'models': [], 'sessions': [], 'timestamp': 1, ...extra},
);

void main() {
  setUpAll(() => AppL10n.init('zh'));

  group('能力表解析', () {
    test('快照携带 hostVersion 与 capabilities 时正确解析', () {
      final state = AppState();
      state.applyEnvelope(
        snapshot({
          'hostVersion': '0.2.1-rc.2',
          'capabilities': {
            'session.create': true,
            'session.setModel': false,
            'session.delete': 'own-only',
          },
        }),
      );
      expect(state.hostVersion, '0.2.1-rc.2');
      expect(state.hostCapabilities['session.create'], true);
      expect(state.capabilityOff('session.setModel'), true);
      expect(state.capabilityOff('session.delete'), false); // own-only 不算关闭
      expect(state.capabilityOff('session.create'), false);
    });

    test('仅显式 false 降级；缺省键与未知键保持原有行为', () {
      final state = AppState();
      state.applyEnvelope(
        snapshot({
          'capabilities': {'session.setModel': false},
        }),
      );
      expect(state.capabilityOff('session.setModel'), true);
      expect(state.capabilityOff('session.delete'), false); // 缺省
      expect(state.capabilityOff('future.unknown'), false); // 未知键
    });

    test('旧版插件快照（无能力字段）清空能力表，完全向后兼容', () {
      final state = AppState();
      state.applyEnvelope(
        snapshot({
          'hostVersion': 'x',
          'capabilities': {'session.setModel': false},
        }),
      );
      state.applyEnvelope(snapshot({})); // 旧插件快照
      expect(state.hostVersion, isNull);
      expect(state.hostCapabilities, isEmpty);
      expect(state.capabilityOff('session.setModel'), false);
    });
  });

  group('会话内模型切换', () {
    test('setSessionModel 发送 session.set_model 并透传响应', () async {
      final seen = <Map<String, dynamic>>[];
      final relay = FakeRelay(onConnection: (conn) {
        conn.onEnvelope = (env) {
          if (env.type == MsgType.helloMobile) {
            conn.send(makeEnvelope(MsgType.helloOk, {}));
          } else if (env.type == MsgType.cmdDispatch &&
              env.payloadMap['action'] == 'session.set_model') {
            seen.add(Map<String, dynamic>.from(env.payloadMap['data'] as Map));
            conn.send(
              makeEnvelope(MsgType.rpcResponse, {
                'ok': true,
                'result': {'sessionId': 's1', 'model': 'qwen4-max'},
              }, {'reqId': env.reqId}),
            );
          } else if (env.type == MsgType.cmdDispatch &&
              env.payloadMap['action'] == 'device.token.get') {
            conn.send(
              makeEnvelope(MsgType.rpcResponse, {
                'ok': true,
                'result': {'token': 't', 'relayUrl': 'ws://127.0.0.1:0/ws'},
              }, {'reqId': env.reqId}),
            );
          } else if (env.type == MsgType.cmdDispatch) {
            conn.send(
              makeEnvelope(MsgType.rpcResponse, {
                'ok': true,
                'result': {},
              }, {'reqId': env.reqId}),
            );
          }
        };
      });
      await relay.start();
      addTearDown(relay.stop);
      final state = AppState();
      state.connect(
        RelayClient(
          url: relay.url,
          deviceToken: 't',
          allowUnencryptedForTests: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final resp = await state.setSessionModel('s1', 'qwen4-max');
      expect(resp.payloadMap['ok'], true);
      expect(seen, [
        {'sessionId': 's1', 'modelId': 'qwen4-max'},
      ]);
      state.client?.stop();
      state.dispose();
    });
  });

  group('模型选择器能力降级', () {
    Future<void> openPicker(WidgetTester tester, AppState state) async {
      await tester.pumpWidget(
        MaterialApp(home: SessionPage(state: state, sessionId: 'cap-test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.tune));
      await tester.pumpAndSettle();
    }

    testWidgets('已有会话 + 宿主明确不支持切换 → 显示仅新会话生效提示', (tester) async {
      final state = _OfflineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      state.applyEnvelope(
        snapshot({
          'capabilities': {'session.setModel': false},
        }),
      );
      await openPicker(tester, state);
      expect(find.text(AppL10n.i.modelNewSessionOnly), findsOneWidget);
    });

    testWidgets('旧插件（无能力表）→ 不显示提示，保持原有行为', (tester) async {
      final state = _OfflineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      state.applyEnvelope(snapshot({}));
      await openPicker(tester, state);
      expect(find.text(AppL10n.i.modelNewSessionOnly), findsNothing);
    });

    testWidgets('宿主支持切换（能力 true）→ 不显示提示', (tester) async {
      final state = _OfflineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      state.applyEnvelope(
        snapshot({
          'capabilities': {'session.setModel': true},
        }),
      );
      await openPicker(tester, state);
      expect(find.text(AppL10n.i.modelNewSessionOnly), findsNothing);
    });
  });
}
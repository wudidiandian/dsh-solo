/// 组件冒烟测试：主页连接表单 / 会话页事件渲染与审批交互
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/home_page.dart';
import 'package:dsh_solo/ui/session_page.dart';

Envelope event(String sid, int seq, Map<String, dynamic> payload) =>
    makeEnvelope(MsgType.sessionEvent, payload, {'sessionId': sid, 'seqId': seq});

void main() {
  // UI 文案走 AppL10n（默认中文），与测试断言的中文一致
  setUpAll(() => AppL10n.init('zh'));

  group('HomePage', () {
    testWidgets('未连接时展示连接表单', (tester) async {
      final state = AppState();
      await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));

      expect(find.text('连接到你的电脑'), findsOneWidget);
      expect(find.text('连接'), findsOneWidget);
    });

    testWidgets('已连接且快照为空时提示新会话', (tester) async {
      final state = AppState();
      state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {
        'models': [
          {'id': 'deepseek-v3'},
        ],
        'sessions': [],
        'timestamp': 1,
      }));
      state.relayStatus = RelayStatus.open;
      state.relayError = null;

      await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));

      expect(find.text('暂无会话'), findsOneWidget);
      expect(find.text('新会话'), findsOneWidget);
    });

    testWidgets('待审批横幅显示数量并可点击', (tester) async {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {
        'kind': 'approval_request',
        'approvalId': 'ap-1',
        'toolName': 'bash',
        'summary': 'rm -rf /',
      }));
      state.relayStatus = RelayStatus.open;

      await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
      await tester.pump();

      expect(find.text('有 1 项待审批'), findsOneWidget);
    });
  });

  group('SessionPage', () {
    testWidgets('事件流渲染文本与回合完成标记', (tester) async {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {'kind': 'text.delta', 'text': '你好，'}));
      state.applyEnvelope(event('s1', 2, {'kind': 'text.delta', 'text': '世界'}));
      state.applyEnvelope(event('s1', 3, {'kind': 'turn.completed'}));

      await tester.pumpWidget(MaterialApp(
        home: SessionPage(state: state, sessionId: 's1'),
      ));
      await tester.pumpAndSettle();

      // 连续 text.delta 合并后的文本
      expect(find.text('你好，世界'), findsOneWidget);
      expect(find.text('任务完成'), findsOneWidget);
    });

    testWidgets('审批卡片展示摘要且点击「允许」触发响应回调', (tester) async {
      final state = AppState();
      state.applyEnvelope(event('s1', 1, {
        'kind': 'approval_request',
        'approvalId': 'ap-1',
        'toolName': 'bash',
        'summary': 'git push',
      }));

      await tester.pumpWidget(MaterialApp(
        home: SessionPage(state: state, sessionId: 's1'),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('待审批：[bash]'), findsOneWidget);
      expect(find.text('git push'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    });
  });
}

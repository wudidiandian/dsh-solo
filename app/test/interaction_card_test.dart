import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/ui/interaction_card.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/ui/session_page.dart';

void main() {
  setUpAll(() => AppL10n.init('zh'));
  testWidgets(
    'failed approval submission leaves explicit allow and deny controls available',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InteractionCard(
              request: {
                'id': 'a',
                'type': 'approval',
                'toolName': 'pwsh',
                'reason': '需要完整权限',
              },
              onRespond: (response) async {
                calls++;
                expect(response['approved'], true);
                throw StateError('offline');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('允许一次'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('提交失败'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(find.text('拒绝'), findsOneWidget);
    },
  );

  testWidgets(
    'single choice and free text produce a structured answer, without auto-submission',
    (tester) async {
      Map<String, Object?>? submitted;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: InteractionCard(
                request: {
                  'id': 'q1',
                  'type': 'question',
                  'questions': [
                    {
                      'id': 'kind',
                      'question': '想要哪种页面？',
                      'options': [
                        {'label': '看板'},
                        {'label': '小游戏'},
                      ],
                    },
                  ],
                },
                onRespond: (response) async => submitted = response,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('看板'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小游戏'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '贪吃蛇');
      await tester.pump();
      expect(submitted, isNull);
      await tester.ensureVisible(find.text('提交回答'));
      await tester.tap(find.text('提交回答'));
      await tester.pumpAndSettle();
      expect(submitted, {
        'answers': [
          {
            'id': 'kind',
            'selected': ['小游戏'],
            'custom': '贪吃蛇',
          },
        ],
      });
    },
  );

  testWidgets(
    'live approvals are pinned outside historical steps and withdrawn by desktop snapshots',
    (tester) async {
      final state = AppState();
      state.applyEnvelope(
        makeEnvelope(MsgType.agentSnapshot, {
          'sessions': [],
          'pendingInteractions': [
            {
              'id': 'r',
              'type': 'approval',
              'sessionId': 'session-a',
              'toolName': 'pwsh',
              'reason': '等待审批',
            },
          ],
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'session-a'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('允许一次'), findsOneWidget);
      expect(find.text(AppL10n.i.thinking), findsNothing);
      state.applyEnvelope(
        makeEnvelope(MsgType.agentSnapshot, {
          'sessions': [],
          'pendingInteractions': [],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('允许一次'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}

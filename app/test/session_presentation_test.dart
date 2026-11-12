import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/session_page.dart';

class TimelineState extends AppState {
  @override
  Future<Envelope> fetchHistory(String sessionId, {int? sinceSeqId}) async =>
      makeEnvelope(MsgType.rpcResponse, {
        'ok': true,
        'result': {'events': []},
      });
}

Envelope event(int seq, String kind, {Map<String, Object?>? data}) => Envelope(
  type: MsgType.sessionEvent,
  sessionId: 'presentation-test',
  seqId: seq,
  payload: {'kind': kind, if (data != null) 'data': data},
);

Map<String, Object?> message(String text) => {
  'content': [
    {'type': 'text', 'text': text},
  ],
};

class ObservedEnvelope extends Envelope {
  ObservedEnvelope(int seq)
    : super(
        type: MsgType.sessionEvent,
        sessionId: 'presentation-test',
        seqId: seq,
        payload: {
          'kind': 'assistant/message',
          'data': message('历史 $seq\n' * 12),
        },
      );
  int reads = 0;
  @override
  Map<String, dynamic> get payloadMap {
    reads++;
    return super.payloadMap;
  }
}

void main() {
  setUpAll(() => AppL10n.init('zh'));

  testWidgets(
    'history opens with 20 entries and loads an older local page without moving the reader',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      for (var i = 1; i <= 60; i++) {
        state.applyEnvelope(
          event(
            i,
            'user/message',
            data: {
              ...message('历史消息 $i\n${'历史内容\n' * 4}'),
              'source': {'kind': 'user'},
            },
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'presentation-test'),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey('conversation-presentation-test'),
      );
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        21,
      );
      final controller = tester.widget<ListView>(list).controller!;
      // Scroll to the oldest currently exposed row, which starts preloading.
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      final offset = controller.offset;
      expect(
        find.byKey(const ValueKey('older-history-loading')),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ListView>(list).childrenDelegate.estimatedChildCount,
        41,
      );
      expect(controller.offset, closeTo(offset, 1));
      expect(find.byKey(const ValueKey('older-history-loading')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'new replies do not shift the visible historical message while reading',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      for (var i = 1; i <= 30; i++) {
        state.applyEnvelope(
          event(
            i,
            'user/message',
            data: {
              ...message('历史消息 $i\n${'历史内容\n' * 4}'),
              'source': {'kind': 'user'},
            },
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'presentation-test'),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey('conversation-presentation-test'),
      );
      await tester.drag(list, const Offset(0, 250));
      await tester.pumpAndSettle();
      final visible = find
          .byWidgetPredicate(
            (w) => w is Text && (w.data?.startsWith('历史消息') ?? false),
          )
          .hitTestable()
          .first;
      final text = (tester.widget<Text>(visible)).data!;
      final position = tester.getTopLeft(visible);
      state.applyEnvelope(
        event(31, 'assistant/message', data: message('新回复\n' * 25)),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text(text)), position);
      await tester.tap(find.byKey(const ValueKey('return-to-latest')));
      await tester.pumpAndSettle();
      expect(find.textContaining('新回复'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'live stream cannot cancel a near-bottom drag or reprocess cached history',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      final history = [for (var i = 1; i <= 100; i++) ObservedEnvelope(i)];
      for (final e in history) {
        state.applyEnvelope(e);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'presentation-test'),
        ),
      );
      await tester.pumpAndSettle();
      for (final e in history) {
        e.reads = 0;
      }
      final list = find.byKey(
        const PageStorageKey('conversation-presentation-test'),
      );
      final controller = tester.widget<ListView>(list).controller!;
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      final offset = controller.offset;
      expect(controller.position.isScrollingNotifier.value, isTrue);
      for (var i = 0; i < 10; i++) {
        state.applyEnvelope(
          makeEnvelope(
            MsgType.sessionStream,
            {'kind': 'text-delta', 'text': '输出'},
            {'sessionId': 'presentation-test'},
          ),
        );
        state.applyEnvelope(
          makeEnvelope(MsgType.agentSnapshot, {
            'sessions': [
              {'id': 'presentation-test', 'running': true},
            ],
          }),
        );
        await tester.pump();
      }
      expect(controller.position.isScrollingNotifier.value, isTrue);
      expect(controller.offset, closeTo(offset, 1));
      expect(
        history.fold<int>(0, (sum, e) => sum + e.reads),
        0,
        reason:
            'Stream and snapshot updates must not traverse historical payloads',
      );
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets('provisional reply remains visible until durable replacement', (
    tester,
  ) async {
    final state = TimelineState()
      ..relayStatus = RelayStatus.open
      ..agentOnline = true;
    state.applyEnvelope(event(1, 'turn/start'));
    state.applyEnvelope(
      makeEnvelope(
        MsgType.sessionStream,
        {'kind': 'text-delta', 'text': '不能消失的回复'},
        {'sessionId': 'presentation-test'},
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SessionPage(state: state, sessionId: 'presentation-test'),
      ),
    );
    await tester.pumpAndSettle();
    state.applyEnvelope(
      makeEnvelope(
        MsgType.sessionStream,
        {'kind': 'end'},
        {'sessionId': 'presentation-test'},
      ),
    );
    state.applyEnvelope(event(2, 'assistant/attempt'));
    state.applyEnvelope(
      event(
        3,
        'turn/end',
        data: {
          'reason': {'kind': 'completed'},
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('不能消失的回复'), findsOneWidget);
    state.applyEnvelope(
      event(4, 'assistant/message', data: message('不能消失的回复')),
    );
    await tester.pumpAndSettle();
    expect(state.streamingTextOf('presentation-test'), isEmpty);
    expect(find.text('不能消失的回复'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test(
    'file changes are cached across updates and invalidated by new history',
    () async {
      final state = AppState();
      state.applyEnvelope(
        event(
          1,
          'tool/call',
          data: {
            'name': 'write',
            'arguments': '{"file_path":"demo.txt","content":"first"}',
            'turn': 1,
            'step': 1,
          },
        ),
      );
      final changes = state.changesOf('presentation-test');
      expect(changes.single.newText, 'first');
      state.applyEnvelope(
        makeEnvelope(
          MsgType.sessionStream,
          {'kind': 'text-delta', 'text': 'x'},
          {'sessionId': 'presentation-test'},
        ),
      );
      state.applyEnvelope(event(2, 'job/settled'));
      expect(identical(changes, state.changesOf('presentation-test')), isTrue);
      await state.applyHistory('presentation-test', [
        event(
          3,
          'tool/call',
          data: {
            'name': 'write',
            'arguments': '{"file_path":"other.txt","content":"second"}',
            'turn': 1,
            'step': 2,
          },
        ),
      ]);
      expect(state.changesOf('presentation-test').length, 2);
      expect(identical(changes, state.changesOf('presentation-test')), isFalse);
      state.dispose();
    },
  );

  testWidgets(
    'new step groups do not read the conversation scroll offset as expansion state',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      final bucket = PageStorageBucket();
      state.applyEnvelope(event(1, 'assistant/message', data: message('已有回复')));
      await tester.pumpWidget(
        MaterialApp(
          home: PageStorage(
            bucket: bucket,
            child: SessionPage(state: state, sessionId: 'presentation-test'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey('conversation-presentation-test'),
      );
      // ScrollPosition saves a double in the list's PageStorage namespace. A new
      // ExpansionTile without its own PageStorageKey reads that double as bool.
      bucket.writeState(tester.element(list), 123.0);
      state.applyEnvelope(event(2, 'tool/call', data: {'name': 'pwsh'}));
      state.applyEnvelope(event(3, 'tool/result', data: {'isError': true}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('执行步骤（2）'), findsOneWidget);
      expect(find.text('部分步骤失败'), findsOneWidget);
      await tester.tap(find.text('执行步骤（2）'));
      await tester.pumpAndSettle();
      expect(find.text('工具执行失败'), findsOneWidget);
      expect(bucket.readState(tester.element(list)), isA<double>());
      // A second group has its own default state, even after the first was open.
      state.applyEnvelope(event(4, 'assistant/message', data: message('继续处理')));
      state.applyEnvelope(event(5, 'job/registered'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('job/registered'), findsNothing);
      expect(find.text('工具执行失败'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'tool and internal steps are collapsed, expandable, and stay expanded on status refresh',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      state.applyEnvelope(event(1, 'tool/call', data: {'name': 'pwsh'}));
      state.applyEnvelope(event(2, 'job/registered'));
      state.applyEnvelope(event(3, 'job/settled'));
      state.applyEnvelope(event(4, 'tool/result', data: {'isError': true}));
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'presentation-test'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('执行步骤（4）'), findsOneWidget);
      expect(find.text('部分步骤失败'), findsOneWidget);
      expect(find.text('job/registered'), findsNothing);
      await tester.tap(find.text('执行步骤（4）'));
      await tester.pumpAndSettle();
      expect(find.text('job/registered'), findsOneWidget);
      state.applyEnvelope(
        makeEnvelope(MsgType.agentSnapshot, {
          'sessions': [
            {'id': 'presentation-test', 'running': false},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('job/registered'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'reading history preserves scroll offset across streaming and snapshot refresh; latest button resumes following',
    (tester) async {
      final state = TimelineState()
        ..relayStatus = RelayStatus.open
        ..agentOnline = true;
      for (var i = 1; i <= 35; i++) {
        state.applyEnvelope(
          event(
            i,
            'assistant/message',
            data: message('消息 $i：' + '这是需要保留阅读位置的较长历史回复。' * 8),
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'presentation-test'),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(
        const PageStorageKey('conversation-presentation-test'),
      );
      final controller = tester.widget<ListView>(list).controller!;
      expect(controller.position.extentBefore, lessThan(2));
      await tester.drag(list, const Offset(0, 600));
      await tester.pumpAndSettle();
      final readingOffset = controller.offset;
      expect(controller.position.extentBefore, greaterThan(200));
      expect(find.byKey(const ValueKey('return-to-latest')), findsOneWidget);
      state.applyEnvelope(
        makeEnvelope(
          MsgType.sessionStream,
          {'kind': 'text-delta', 'text': '实时输出'},
          {'sessionId': 'presentation-test'},
        ),
      );
      state.applyEnvelope(
        makeEnvelope(MsgType.agentSnapshot, {
          'sessions': [
            {'id': 'presentation-test', 'running': true},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(readingOffset, 1));
      await tester.tap(find.byKey(const ValueKey('return-to-latest')));
      await tester.pumpAndSettle();
      expect(controller.position.extentBefore, lessThan(2));
      state.applyEnvelope(
        makeEnvelope(
          MsgType.sessionStream,
          {'kind': 'text-delta', 'text': '继续输出' * 100},
          {'sessionId': 'presentation-test'},
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.position.extentBefore, lessThan(2));
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  test('snapshot restores running status for desktop sessions without receiving turn/start', () {
    final state = AppState();
    state.applyEnvelope(
      makeEnvelope(MsgType.agentSnapshot, {
        'sessions': [
          {'id': 'desktop-running', 'running': true},
          {'id': 'desktop-idle', 'running': false},
        ],
      }),
    );
    expect(state.isBusy('desktop-running'), isTrue);
    expect(state.isBusy('desktop-idle'), isFalse);
    state.applyEnvelope(
      makeEnvelope(MsgType.agentSnapshot, {
        'sessions': [
          {'id': 'desktop-running', 'running': false},
        ],
      }),
    );
    expect(state.isBusy('desktop-running'), isFalse);
    state.dispose();
  });
}

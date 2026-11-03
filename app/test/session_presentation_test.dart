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
      makeEnvelope(MsgType.rpcResponse, {'ok': true, 'result': {'events': []}});
}

Envelope event(int seq, String kind, {Map<String, Object?>? data}) =>
    Envelope(type: MsgType.sessionEvent, sessionId: 'presentation-test', seqId: seq,
      payload: {'kind': kind, if (data != null) 'data': data});

Map<String, Object?> message(String text) => {'content': [{'type': 'text', 'text': text}]};

void main() {
  setUpAll(() => AppL10n.init('zh'));

  testWidgets('new step groups do not read the conversation scroll offset as expansion state', (tester) async {
    final state = TimelineState()..relayStatus = RelayStatus.open..agentOnline = true;
    final bucket = PageStorageBucket();
    state.applyEnvelope(event(1, 'assistant/message', data: message('已有回复')));
    await tester.pumpWidget(MaterialApp(home: PageStorage(bucket: bucket,
      child: SessionPage(state: state, sessionId: 'presentation-test'))));
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('conversation-presentation-test'));
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
  });

  testWidgets('tool and internal steps are collapsed, expandable, and stay expanded on status refresh', (tester) async {
    final state = TimelineState()..relayStatus = RelayStatus.open..agentOnline = true;
    state.applyEnvelope(event(1, 'tool/call', data: {'name': 'pwsh'}));
    state.applyEnvelope(event(2, 'job/registered'));
    state.applyEnvelope(event(3, 'job/settled'));
    state.applyEnvelope(event(4, 'tool/result', data: {'isError': true}));
    await tester.pumpWidget(MaterialApp(home: SessionPage(state: state, sessionId: 'presentation-test')));
    await tester.pumpAndSettle();
    expect(find.text('执行步骤（4）'), findsOneWidget);
    expect(find.text('部分步骤失败'), findsOneWidget);
    expect(find.text('job/registered'), findsNothing);
    await tester.tap(find.text('执行步骤（4）'));
    await tester.pumpAndSettle();
    expect(find.text('job/registered'), findsOneWidget);
    state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {'sessions': [{'id': 'presentation-test', 'running': false}]}));
    await tester.pumpAndSettle();
    expect(find.text('job/registered'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('reading history preserves scroll offset across streaming and snapshot refresh; latest button resumes following', (tester) async {
    final state = TimelineState()..relayStatus = RelayStatus.open..agentOnline = true;
    for (var i = 1; i <= 35; i++) {
      state.applyEnvelope(event(i, 'assistant/message', data: message('消息 $i：' + '这是需要保留阅读位置的较长历史回复。' * 8)));
    }
    await tester.pumpWidget(MaterialApp(home: SessionPage(state: state, sessionId: 'presentation-test')));
    await tester.pumpAndSettle();
    final list = find.byKey(const PageStorageKey('conversation-presentation-test'));
    final controller = tester.widget<ListView>(list).controller!;
    expect(controller.position.extentAfter, lessThan(2));
    await tester.drag(list, const Offset(0, 600));
    await tester.pumpAndSettle();
    final readingOffset = controller.offset;
    expect(controller.position.extentAfter, greaterThan(200));
    expect(find.byKey(const ValueKey('return-to-latest')), findsOneWidget);
    state.applyEnvelope(makeEnvelope(MsgType.sessionStream, {'kind': 'text-delta', 'text': '实时输出'}, {'sessionId': 'presentation-test'}));
    state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {'sessions': [{'id': 'presentation-test', 'running': true}]}));
    await tester.pumpAndSettle();
    expect(controller.offset, closeTo(readingOffset, 1));
    await tester.tap(find.byKey(const ValueKey('return-to-latest')));
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, lessThan(2));
    state.applyEnvelope(makeEnvelope(MsgType.sessionStream, {'kind': 'text-delta', 'text': '继续输出' * 100}, {'sessionId': 'presentation-test'}));
    await tester.pumpAndSettle();
    expect(controller.position.extentAfter, lessThan(2));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  test('snapshot restores running status for desktop sessions without receiving turn/start', () {
    final state = AppState();
    state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {'sessions': [
      {'id': 'desktop-running', 'running': true}, {'id': 'desktop-idle', 'running': false},
    ]}));
    expect(state.isBusy('desktop-running'), isTrue);
    expect(state.isBusy('desktop-idle'), isFalse);
    state.applyEnvelope(makeEnvelope(MsgType.agentSnapshot, {'sessions': [{'id': 'desktop-running', 'running': false}]}));
    expect(state.isBusy('desktop-running'), isFalse);
    state.dispose();
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/session_page.dart';

class ProjectState extends AppState {
  final sent = <Map<String, String?>>[];
  @override
  Future<List<ProjectEntry>> listProjects() async => [const ProjectEntry(id: 'demo-id', title: 'Demo project')];
  @override
  Future<Envelope> fetchHistory(String sessionId, {int? sinceSeqId}) async =>
    makeEnvelope(MsgType.rpcResponse, {'ok': true, 'result': {'events': []}});
  @override
  Future<Envelope> sendPrompt(String text, {String? sessionId, String? modelId, String? projectId}) async {
    sent.add({'sessionId': sessionId, 'projectId': projectId});
    return makeEnvelope(MsgType.rpcResponse, {'ok': true, 'result': {'sessionId': sessionId ?? 'new-session'}});
  }
}

void main() {
  setUpAll(() => AppL10n.init('zh'));
  testWidgets('project menu selects metadata, creates a new session and preserves existing sessions', (tester) async {
    final state = ProjectState()..relayStatus = RelayStatus.open..agentOnline = true;
    state.sessions = [const SessionEntry(id: 'original')];
    await tester.pumpWidget(MaterialApp(home: SessionPage(state: state, sessionId: 'original')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
    expect(find.text('电脑文件'), findsNothing);
    await tester.tap(find.text('选择项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demo project'));
    await tester.pumpAndSettle();
    expect(state.sent, isEmpty);
    expect(state.pendingAttachments, isEmpty);
    await tester.enterText(find.byType(TextField).first, 'test task');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(state.sent.single, {'sessionId': null, 'projectId': 'demo-id'});
    expect(state.sessions.single.id, 'original');
    await tester.enterText(find.byType(TextField).first, 'follow up');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(state.sent.last, {'sessionId': 'new-session', 'projectId': null});
  });

  testWidgets('a new conversation asks for a project and cancellation keeps the draft', (tester) async {
    final state = ProjectState()..relayStatus = RelayStatus.open..agentOnline = true;
    await tester.pumpWidget(MaterialApp(home: SessionPage(state: state)));
    await tester.enterText(find.byType(TextField).first, 'unsent draft');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('选择项目'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.sent, isEmpty);
    expect(find.text('unsent draft'), findsOneWidget);
  });
}

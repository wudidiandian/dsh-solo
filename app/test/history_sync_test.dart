import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/session_page.dart';

Envelope record(int seq, String kind, String text) => Envelope(
  type: MsgType.sessionEvent,
  sessionId: 'gap-diagnostic',
  seqId: seq,
  payload: {
    'seqId': seq,
    'kind': kind,
    'data': {
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': text},
      ],
    },
  },
);

class DiagnosticState extends AppState {
  final requested = <int?>[];
  final full = [
    record(10, 'user/message', '更早的问题'),
    record(11, 'assistant/message', '更早的回复'),
    record(20, 'user/message', '漏掉的问题'),
    record(21, 'assistant/message', '最新回复'),
  ];
  @override
  Future<Envelope> fetchHistory(String id, {int? sinceSeqId}) async {
    requested.add(sinceSeqId);
    return makeEnvelope(MsgType.rpcResponse, {
      'ok': true,
      'result': {
        'events': full
            .where((e) => sinceSeqId == null || e.seqId! > sinceSeqId)
            .map((e) => e.payloadMap)
            .toList(),
      },
    });
  }
}

class PagedState extends DiagnosticState {
  final pages = <int?>[];
  bool failNext = false;
  @override
  final full = [
    for (var i = 1; i <= 12; i++) record(i, 'user/message', '历史问题 $i'),
  ];
  @override
  Future<Envelope> fetchHistoryPage(String id, {int? beforeSeqId}) async {
    pages.add(beforeSeqId);
    if (failNext) {
      failNext = false;
      throw StateError('temporary disconnect');
    }
    final eligible = full
        .where((e) => beforeSeqId == null || e.seqId! < beforeSeqId)
        .toList();
    final events = eligible
        .skip((eligible.length - 4).clamp(0, eligible.length))
        .toList();
    return makeEnvelope(MsgType.rpcResponse, {
      'ok': true,
      'result': {
        'events': events.map((e) => e.payloadMap).toList(),
        'hasMore': eligible.length > events.length,
        'beforeSeqId': events.first.seqId,
      },
    });
  }
}

class DelayedHostState extends AppState {
  final response = Completer<Envelope>();
  @override
  Future<Envelope> fetchHistoryPage(String id, {int? beforeSeqId}) =>
      response.future;
}

void main() {
  setUpAll(() => AppL10n.init('zh'));
  testWidgets(
    'initial full history fills earlier messages despite a newer live tail',
    (tester) async {
      final state = DiagnosticState();
      state.applyEnvelope(state.full[2]);
      state.applyEnvelope(state.full[3]);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'gap-diagnostic'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      debugPrint(
        'HISTORY GAP: requested since=${state.requested}; local events=${state.eventsOf("gap-diagnostic").length}; available events=${state.full.length}',
      );
      expect(state.requested, [null]);
      expect(state.eventsOf('gap-diagnostic').length, 4);
      expect(find.text('更早的问题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'history repairs a missing question between cache and a newer reply',
    (tester) async {
      final state = DiagnosticState();
      state.applyCached('gap-diagnostic', state.full.take(2).toList());
      state.applyEnvelope(state.full[3]);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'gap-diagnostic'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      debugPrint(
        'HISTORY GAP: cached prefix plus newest reply requested since=${state.requested}; missing question remains=${!state.eventsOf("gap-diagnostic").any((e) => e.seqId == 20)}',
      );
      expect(state.requested, [null]);
      expect(
        state.eventsOf('gap-diagnostic').any((e) => e.seqId == 20),
        isTrue,
      );
      expect(find.text('漏掉的问题'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  test('cached prefix merges with live tail and preserves streaming', () async {
    final state = DiagnosticState();
    state.applyEnvelope(state.full.last);
    state.applyCached('gap-diagnostic', state.full.take(2).toList());
    expect(state.eventsOf('gap-diagnostic').map((e) => e.seqId), [10, 11, 21]);
    state.applyEnvelope(state.full[2]);
    expect(state.eventsOf('gap-diagnostic').map((e) => e.seqId), [
      10,
      11,
      20,
      21,
    ]);
    state.applyEnvelope(state.full[2]);
    expect(state.eventsOf('gap-diagnostic').length, 4);
    state.dispose();
  });
  test('canonical host history replaces colliding legacy IDs and rejects stale cache', () async {
    final state = DiagnosticState();
    state.applyCached('gap-diagnostic', state.full);
    final host = Envelope(
      type: MsgType.sessionEvent,
      sessionId: 'gap-diagnostic',
      seqId: 1,
      payload: {
        'seqId': 1,
        'historyEpoch': 'host-v1',
        'kind': 'assistant/message',
        'data': {'content': []},
      },
    );
    state.applyEnvelope(host);
    state.applyCached('gap-diagnostic', state.full);
    expect(state.eventsOf('gap-diagnostic'), [host]);
    expect(state.lastSeq['gap-diagnostic'], 1);
    state.dispose();
  });
  testWidgets(
    'older pages are fetched from desktop even when a partial cache exists',
    (tester) async {
      final state = PagedState();
      state.applyCached('gap-diagnostic', [state.full.first, state.full.last]);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'gap-diagnostic'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(state.pages, [null]);
      // An old cache island must not masquerade as a complete synchronized range.
      expect(find.text('历史问题 1'), findsNothing);
      final older = find.byKey(const ValueKey('load-older-history'));
      await tester.ensureVisible(older);
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(state.pages, [null, 9]);
      await tester.ensureVisible(older);
      await tester.tap(older);
      await tester.pumpAndSettle();
      expect(state.pages, [null, 9, 5]);
      expect(
        state.eventsOf('gap-diagnostic').map((e) => e.seqId),
        List.generate(12, (i) => i + 1),
      );
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  testWidgets(
    'failed initial history shows retry even when the view is empty',
    (tester) async {
      final state = PagedState()..failNext = true;
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'gap-diagnostic'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('retry-history-sync')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(state.pages, [null, null]);
      expect(state.eventsOf('gap-diagnostic').length, 4);
      expect(find.byKey(const ValueKey('retry-history-sync')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
  test('late durable reply clears provisional text only if no newer turn has started', () {
    final state = DiagnosticState();
    state.applyEnvelope(record(21, 'turn/end', ''));
    state.applyEnvelope(
      Envelope(
        type: MsgType.sessionStream,
        sessionId: 'gap-diagnostic',
        payload: {'kind': 'text-delta', 'text': 'provisional'},
      ),
    );
    state.applyEnvelope(record(20, 'assistant/message', 'durable'));
    expect(state.streamingTextOf('gap-diagnostic'), isEmpty);
    state.applyEnvelope(record(30, 'turn/start', ''));
    state.applyEnvelope(
      Envelope(
        type: MsgType.sessionStream,
        sessionId: 'gap-diagnostic',
        payload: {'kind': 'text-delta', 'text': 'new turn'},
      ),
    );
    state.applyEnvelope(record(25, 'assistant/message', 'older turn'));
    expect(state.streamingTextOf('gap-diagnostic'), 'new turn');
    state.dispose();
  });
  testWidgets(
    'paused legacy cache remains readable after host sequence migration',
    (tester) async {
      final state = DelayedHostState();
      final legacy = [
        for (var i = 1; i <= 50; i++) record(i, 'user/message', '缓存消息 $i'),
      ];
      state.applyCached('gap-diagnostic', legacy);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionPage(state: state, sessionId: 'gap-diagnostic'),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      state.response.complete(
        makeEnvelope(MsgType.rpcResponse, {
          'ok': true,
          'result': {
            'events': [
              for (final e in legacy)
                {
                  ...e.payloadMap,
                  'seqId': 1000000000000 + e.seqId!,
                  'seq': e.seqId! - 1,
                  'historyEpoch': 'host-v1',
                },
            ],
            'hasMore': false,
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(state.eventsOf('gap-diagnostic').length, 50);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}

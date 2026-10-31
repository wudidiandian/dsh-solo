import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';

import 'fake_relay.dart';

void main() {
  setUpAll(() => AppL10n.init('zh'));
  test('wrong token clears old data and cannot become connected', () async {
    final relay = FakeRelay(
      onConnection: (conn) {
        String? token;
        conn.onEnvelope = (env) {
          if (env.type == MsgType.helloMobile) {
            token = env.payloadMap['deviceToken'] as String;
            conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
          } else if (env.type == MsgType.cmdDispatch) {
            conn.send(
              makeEnvelope(
                MsgType.rpcResponse,
                token == 'correct-token'
                    ? {
                        'ok': true,
                        'result': {'token': token},
                      }
                    : {'ok': false, 'error': 'agent offline'},
                {'reqId': env.reqId},
              ),
            );
            if (token == 'correct-token') {
              conn.send(
                makeEnvelope(MsgType.agentSnapshot, {
                  'models': [
                    {'id': 'desktop-model'},
                  ],
                  'sessions': [
                    {'id': 'private-session'},
                  ],
                }),
              );
            }
          }
        };
      },
    );
    await relay.start();
    final state = AppState();
    try {
      final old = RelayClient(url: relay.url, deviceToken: 'correct-token');
      state.connect(old);
      await waitFor(
        () => state.isDesktopConnected && state.sessions.isNotEmpty,
      );
      final lateStatus = old.onStatus!;
      final lateEnvelope = old.onEnvelope!;
      state.connect(RelayClient(url: relay.url, deviceToken: 'wrong-token'));
      expect(state.isDesktopConnected, isFalse);
      expect(state.sessions, isEmpty);
      expect(state.models, isEmpty);
      lateStatus(RelayStatus.open, null);
      lateEnvelope(
        makeEnvelope(MsgType.agentSnapshot, {
          'sessions': [
            {'id': 'old-device'},
          ],
        }),
      );
      expect(state.sessions, isEmpty);
      await waitFor(
        () =>
            state.relayStatus == RelayStatus.open && state.desktopError != null,
      );
      expect(state.isDesktopConnected, isFalse);
      await expectLater(state.sendPrompt('must not be sent'), throwsStateError);
      expect(
        relay.conns
            .expand((c) => c.received)
            .where(
              (e) =>
                  e.type == MsgType.cmdDispatch &&
                  e.payloadMap['action'] == CmdAction.sessionPrompt,
            ),
        isEmpty,
      );
    } finally {
      state.dispose();
      await relay.stop();
    }
  });

  test(
    'cached snapshots do not prove online status and pairing can recover',
    () async {
      var online = false;
      final relay = FakeRelay(
        onConnection: (conn) {
          conn.onEnvelope = (env) {
            if (env.type == MsgType.helloMobile) {
              conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
              conn.send(
                makeEnvelope(MsgType.agentSnapshot, {
                  'sessions': [
                    {'id': 'cached'},
                  ],
                }),
              );
            } else if (env.type == MsgType.cmdDispatch) {
              conn.send(
                makeEnvelope(
                  MsgType.rpcResponse,
                  online
                      ? {
                          'ok': true,
                          'result': {'token': 'correct-token'},
                        }
                      : {'ok': false, 'error': 'agent offline'},
                  {'reqId': env.reqId},
                ),
              );
            }
          };
        },
      );
      await relay.start();
      final state = AppState();
      try {
        state.connect(
          RelayClient(url: relay.url, deviceToken: 'correct-token'),
        );
        await waitFor(
          () => state.desktopError != null && state.sessions.isNotEmpty,
        );
        expect(state.isDesktopConnected, isFalse);
        online = true;
        state.connect(
          RelayClient(url: relay.url, deviceToken: 'correct-token'),
        );
        await waitFor(() => state.isDesktopConnected);
        expect(state.desktopError, isNull);
        state.applyEnvelope(
          makeEnvelope(MsgType.rpcResponse, {
            'ok': false,
            'error': 'agent offline',
          }),
        );
        expect(state.relayStatus, RelayStatus.open);
        expect(state.isDesktopConnected, isFalse);
      } finally {
        state.dispose();
        await relay.stop();
      }
    },
  );
}

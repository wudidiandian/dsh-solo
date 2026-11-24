import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';

import 'fake_relay.dart';

/// 回前台恢复链路（iOS 挂起 / 锁屏 / 切网后的半开连接）。
void main() {
  setUpAll(() => AppL10n.init('zh'));

  /// 长退避：确保重连只能由 onAppResumed 触发，而不是自动退避定时器。
  RelayClient client(String url) => RelayClient(
    allowUnencryptedForTests: true,
    url: url,
    deviceToken: 't',
    baseBackoffMs: 60000,
    maxBackoffMs: 60000,
  );

  FakeRelay relayWith(Set<FakeConn> silent) => FakeRelay(
    onConnection: (conn) {
      conn.onEnvelope = (env) {
        if (silent.contains(conn)) return;
        if (env.type == MsgType.helloMobile) {
          conn.send(makeEnvelope(MsgType.helloOk, {'role': 'mobile'}));
        } else if (env.type == MsgType.cmdDispatch) {
          conn.send(
            makeEnvelope(MsgType.rpcResponse, {
              'ok': true,
              'result': {'token': 't'},
            }, {'reqId': env.reqId}),
          );
        }
      };
    },
  );

  test('resume rebuilds a closed socket and re-requests session deltas', () async {
    final silent = <FakeConn>{};
    final relay = relayWith(silent);
    await relay.start();
    final state = AppState();
    try {
      state.connect(client(relay.url));
      await waitFor(() => state.isDesktopConnected);
      state.lastSeq['s1'] = 3;
      state.appInBackground = true;

      // 模拟 iOS 挂起期间服务端断开
      await relay.conns.first.close();
      await waitFor(() => state.relayStatus == RelayStatus.closed);
      final before = relay.conns.length;

      await state.onAppResumed();
      await waitFor(() => state.isDesktopConnected);
      expect(state.appInBackground, isFalse);
      expect(relay.conns.length, before + 1);
      await waitFor(
        () => relay.conns.last.received.any(
          (e) =>
              e.type == MsgType.syncRequest &&
              e.payloadMap['sessionId'] == 's1' &&
              e.payloadMap['lastSeqId'] == 3,
        ),
      );
    } finally {
      state.dispose();
      await relay.stop();
    }
  });

  test('resume detects a half-open socket by probe timeout and rebuilds', () async {
    final silent = <FakeConn>{};
    final relay = relayWith(silent);
    await relay.start();
    final state = AppState();
    try {
      state.connect(client(relay.url));
      await waitFor(() => state.isDesktopConnected);
      // 半开：socket 看似 open，但对端不再回应任何报文
      silent.add(relay.conns.first);
      expect(state.relayStatus, RelayStatus.open);

      final sw = Stopwatch()..start();
      await state.onAppResumed();
      sw.stop();
      // 探测超时 5s 后才判定链路已死
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(4000));
      await waitFor(() => state.isDesktopConnected);
      expect(relay.conns.length, 2);
    } finally {
      state.dispose();
      await relay.stop();
    }
  });

  test('resume does not retry after a fatal auth failure', () async {
    final silent = <FakeConn>{};
    final relay = relayWith(silent);
    await relay.start();
    final state = AppState();
    try {
      final c = client(relay.url);
      state.connect(c);
      await waitFor(() => state.isDesktopConnected);
      c.status = RelayStatus.fatal;
      final before = relay.conns.length;
      await state.onAppResumed();
      expect(relay.conns.length, before);
      expect(c.status, RelayStatus.fatal);
    } finally {
      state.dispose();
      await relay.stop();
    }
  });
}
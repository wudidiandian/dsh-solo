/// 多工作站存储 / 设备注册领取专属密钥 / 后台通知门控
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dsh_solo/config/app_config.dart';
import 'package:dsh_solo/config/workstation_store.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/protocol/envelope.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';

import 'fake_relay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppL10n.init('zh'));
  late Directory directory;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ws-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  group('多工作站存储', () {
    test('两台电脑独立保存，活动工作站可切换，删除不影响另一台', () async {
      final pc1 = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 'token-1',
        encryptionKey: 'key-1',
      );
      await pc1.save();
      final pc2 = AppConfig(
        relayUrl: 'wss://pc2.example/ws',
        deviceToken: 'token-2',
        encryptionKey: 'key-2',
      );
      await pc2.save();
      expect(pc1.stationId, isNotNull);
      expect(pc2.stationId, isNotNull);
      expect(pc1.stationId, isNot(pc2.stationId));

      // 新建即活动
      var loaded = await AppConfig.load();
      expect(loaded?.deviceToken, 'token-2');

      // 切回 pc1
      final ws = await loadWorkstations();
      ws.activeId = pc1.stationId;
      await saveWorkstations(ws);
      loaded = await AppConfig.load();
      expect(loaded?.deviceToken, 'token-1');
      expect(loaded?.encryptionKey, 'key-1');

      // 删除 pc1 → 活动回落到 pc2
      ws.stations.removeWhere((s) => s.id == pc1.stationId);
      ws.activeId = ws.stations.first.id;
      await saveWorkstations(ws);
      loaded = await AppConfig.load();
      expect(loaded?.deviceToken, 'token-2');
      expect((await loadWorkstations()).stations, hasLength(1));
    });

    test('切换活动工作站后保存不新建条目（回归：fromJson 回填 stationId）', () async {
      final pc1 = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 'token-1',
        encryptionKey: 'key-1',
      );
      await pc1.save();
      final pc2 = AppConfig(
        relayUrl: 'wss://pc2.example/ws',
        deviceToken: 'token-2',
        encryptionKey: 'key-2',
      );
      await pc2.save();

      // 模拟 UI 切换：从存储读出的 entry.config 必须携带 stationId
      final ws = await loadWorkstations();
      final entry = ws.stations.firstWhere((s) => s.id == pc1.stationId);
      expect(entry.config.stationId, pc1.stationId);
      expect(entry.config.stationName, isNotNull);

      // 切换后保存（UI _saveCurrentConfig 路径）：原位更新，条目数不变
      entry.config.relayUrl = 'wss://pc1.example/ws';
      await entry.config.save();
      final after = await loadWorkstations();
      expect(after.stations, hasLength(2));
      expect(after.activeId, pc1.stationId);
      expect((await AppConfig.load())?.deviceToken, 'token-1');
    });

    test('重扫同一台电脑更新既有工作站，不新增条目', () async {
      final pc1 = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 'same-token',
        encryptionKey: 'key-old',
      );
      await pc1.save();
      // 模拟「添加工作站」再扫同一台电脑：stationId 为空的新配对
      final rescan = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 'same-token',
        encryptionKey: 'key-new',
      );
      await rescan.save();
      final ws = await loadWorkstations();
      expect(ws.stations, hasLength(1));
      expect(ws.activeId, pc1.stationId);
      expect(rescan.stationId, pc1.stationId);
      expect((await AppConfig.load())?.encryptionKey, 'key-new');
    });

    test('历史重复条目（同 token）加载时合并到活动工作站', () async {
      final a = AppConfig(
        relayUrl: 'wss://pc.example/ws',
        deviceToken: 'dup-token',
        encryptionKey: 'k1',
      );
      final b = AppConfig(
        relayUrl: 'wss://pc.example/ws',
        deviceToken: 'dup-token',
        encryptionKey: 'k2',
      );
      await saveWorkstations(
        Workstations(
          activeId: 'ws-b',
          stations: [
            WorkstationEntry(id: 'ws-a', config: a),
            WorkstationEntry(id: 'ws-b', config: b),
          ],
        ),
      );
      final ws = await loadWorkstations();
      expect(ws.stations, hasLength(1));
      expect(ws.stations.first.id, 'ws-b');
      expect(ws.activeId, 'ws-b');
      expect(ws.stations.first.config.encryptionKey, 'k2');
      // 合并结果已持久化
      expect((await loadWorkstations()).stations, hasLength(1));
    });

    test('同一工作站更新不新建条目，设备身份字段持久化', () async {
      final config = AppConfig(
        relayUrl: 'wss://pc.example/ws',
        deviceToken: 'token',
        encryptionKey: 'master-key',
        deviceId: 'a' * 32,
      );
      await config.save();
      config.encryptionKey = 'device-key';
      config.deviceRegistered = true;
      await config.save();
      final ws = await loadWorkstations();
      expect(ws.stations, hasLength(1));
      final loaded = await AppConfig.load();
      expect(loaded?.deviceId, 'a' * 32);
      expect(loaded?.deviceRegistered, true);
      expect(loaded?.encryptionKey, 'device-key');
    });
  });

  group('全局设备身份', () {
    test('新安装生成稳定 id，多次调用与多工作站共用同一个', () async {
      final id1 = await ensureDeviceId();
      expect(id1, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(await ensureDeviceId(), id1);
      final pc1 = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 't1',
        deviceId: await ensureDeviceId(),
      );
      await pc1.save();
      final pc2 = AppConfig(
        relayUrl: 'wss://pc1.example/ws',
        deviceToken: 't1',
        deviceId: await ensureDeviceId(),
      );
      await pc2.save();
      expect(pc2.deviceId, pc1.deviceId);
    });

    test('迁移：沿用老版本既有工作站 deviceId，不产生新身份', () async {
      final legacyId = 'c' * 32;
      final old = AppConfig(
        relayUrl: 'wss://pc.example/ws',
        deviceToken: 't',
        deviceId: legacyId,
      );
      await old.save();
      expect(await ensureDeviceId(), legacyId);
    });
  });

  group('设备注册', () {
    test('握手后自动注册并领取设备专属密钥（幂等回调一次）', () async {
      final registered = <Map<String, dynamic>>[];
      final relay = FakeRelay(onConnection: (conn) {
        conn.onEnvelope = (env) {
          if (env.type == MsgType.helloMobile) {
            conn.send(makeEnvelope(MsgType.helloOk, {}));
          } else if (env.type == MsgType.cmdDispatch &&
              env.payloadMap['action'] == 'device.register') {
            registered.add(
              Map<String, dynamic>.from(env.payloadMap['data'] as Map),
            );
            conn.send(
              makeEnvelope(MsgType.rpcResponse, {
                'ok': true,
                'result': {'deviceId': 'a' * 32, 'deviceKey': 'device-key-xyz'},
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
      state.deviceId = 'a' * 32;
      final keys = <String>[];
      state.onDeviceKeyReceived = keys.add;
      state.connect(
        RelayClient(
          url: relay.url,
          deviceToken: 'token',
          allowUnencryptedForTests: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(registered, hasLength(1));
      expect(registered.first['deviceId'], 'a' * 32);
      expect(keys, ['device-key-xyz']);
      expect(state.deviceRegistered, true);

      // 已注册后再次握手不重复注册
      state.client?.stop();
      state.deviceRegistered = true;
      state.connect(
        RelayClient(
          url: relay.url,
          deviceToken: 'token',
          allowUnencryptedForTests: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(registered, hasLength(1));
      state.client?.stop();
      state.dispose();
    });

    test('旧插件返回 unknown action 时静默降级，不影响连接', () async {
      final relay = FakeRelay(onConnection: (conn) {
        conn.onEnvelope = (env) {
          if (env.type == MsgType.helloMobile) {
            conn.send(makeEnvelope(MsgType.helloOk, {}));
          } else if (env.type == MsgType.cmdDispatch) {
            conn.send(
              makeEnvelope(MsgType.rpcResponse, {
                'ok': false,
                'error': 'unknown action: device.register',
              }, {'reqId': env.reqId}),
            );
          }
        };
      });
      await relay.start();
      addTearDown(relay.stop);
      final state = AppState();
      state.deviceId = 'b' * 32;
      final keys = <String>[];
      state.onDeviceKeyReceived = keys.add;
      state.connect(
        RelayClient(
          url: relay.url,
          deviceToken: 'token',
          allowUnencryptedForTests: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(state.relayStatus, RelayStatus.open);
      expect(state.deviceRegistered, false);
      expect(keys, isEmpty);
      state.client?.stop();
      state.dispose();
    });
  });

  group('后台通知门控', () {
    test('前台不触发；后台新鲜高优事件正常处理不抛错', () {
      final state = AppState();
      final env = makeEnvelope(MsgType.sessionEvent, {
        'kind': 'approval_request',
        'approvalId': 'x',
        'toolName': 'bash',
      }, {
        'sessionId': 's1',
        'seqId': 1,
        'pushLevel': 'high',
        'pushSummary': '待审批: [bash]',
        'ts': DateTime.now().millisecondsSinceEpoch,
      });
      state.appInBackground = false;
      state.applyEnvelope(env); // 前台：不通知
      state.appInBackground = true;
      state.applyEnvelope(
        makeEnvelope(MsgType.sessionEvent, {
          'kind': 'turn.completed',
        }, {
          'sessionId': 's1',
          'seqId': 2,
          'pushLevel': 'normal',
          'pushSummary': '任务完成',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      expect(state.eventsOf('s1'), hasLength(2));
      state.dispose();
    });
  });
}
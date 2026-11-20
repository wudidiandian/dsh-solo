/// 通知权限上下文化请求：首次连上电脑引导一次；暂不不再打扰；开启才调系统框
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/state/notification_service.dart';
import 'package:dsh_solo/ui/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => AppL10n.init('zh'));
  const notifyChannel = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late List<String> calls;
  late Directory directory;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    calls = [];
    directory = await Directory.systemTemp.createTemp('notify-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (_) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'initialize':
              return true;
            case 'areNotificationsEnabled':
              return false;
            case 'requestNotificationsPermission':
              return true;
            default:
              return null;
          }
        });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifyChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    await directory.delete(recursive: true);
  });

  Future<AppState> connectedState() async {
    final state = AppState()
      ..relayStatus = RelayStatus.open
      ..agentOnline = true;
    return state;
  }

  testWidgets('首次连上电脑弹一次性引导；暂不后持久化且不再打扰', (tester) async {
    // 测试宿主为 Windows：显式指定 Android 并注入平台实现，插件才走 Android 通道
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    await tester.runAsync(() => NotificationService.instance.init());
    final state = await connectedState();
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    state.notifyListeners();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppL10n.i.notifyPromptTitle), findsOneWidget);
    await tester.tap(find.text(AppL10n.i.notNow));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppL10n.i.notifyPromptTitle), findsNothing);
    expect(calls, isNot(contains('requestNotificationsPermission')));
    expect(
      await const FlutterSecureStorage().read(key: 'dsh_solo_notify_prompt_v1'),
      '1',
    );

    // 重建页面（模拟重启后再次连接）：不再弹引导
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    state.notifyListeners();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppL10n.i.notifyPromptTitle), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('点击开启才请求系统通知权限', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterLocalNotificationsPlatform.instance =
        AndroidFlutterLocalNotificationsPlugin();
    await tester.runAsync(() => NotificationService.instance.init());
    final state = await connectedState();
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    state.notifyListeners();
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text(AppL10n.i.notifyPromptTitle), findsOneWidget);
    await tester.tap(find.text(AppL10n.i.enableNotifications));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(calls, contains('requestNotificationsPermission'));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
}
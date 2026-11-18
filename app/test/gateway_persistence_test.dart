import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dsh_solo/config/app_config.dart';
import 'package:dsh_solo/config/defaults.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/home_page.dart';

class FakeState extends AppState {
  final connections = <String>[];
  @override
  void connect(RelayClient client) {
    connections.add(client.url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() => AppL10n.init('zh'));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('gateway-test-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });
  test('international address overlapping legacy survives reload', () async {
    await AppConfig(
      relayUrl: intlRelayUrl,
      deviceToken: 'token',
      encryptionKey: 'secret',
      modelId: 'model',
    ).save();
    final loaded = await AppConfig.load();
    expect(loaded?.relayUrl, intlRelayUrl);
    expect(loaded?.encryptionKey, 'secret');
    expect(loaded?.modelId, 'model');
  });
  testWidgets('unpaired selection survives restart', (tester) async {
    final state = FakeState();
    await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
          .selected,
      {'intl'},
    );
    expect(find.textContaining(Uri.parse(intlRelayUrl).host), findsNothing);
    await tester.tap(find.text('国内节点'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final stored = await tester.runAsync(() => AppConfig.load());
    expect(stored?.relayUrl, defaultRelayUrl);
    expect(stored?.deviceToken, isEmpty);
    expect(state.connections, isEmpty);
    await tester.pumpWidget(const SizedBox());
    final saved = await tester.runAsync(() => AppConfig.load());
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: state, initialConfig: saved),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
          .selected,
      {'cn'},
    );
    expect(find.textContaining(Uri.parse(defaultRelayUrl).host), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
  testWidgets('paired switch preserves keys and reconnects to chosen node', (
    tester,
  ) async {
    final state = FakeState();
    final initial = AppConfig(
      relayUrl: defaultRelayUrl,
      deviceToken: 'token',
      encryptionKey: 'key',
      modelId: 'model',
    );
    await tester.runAsync(() => initial.save());
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(state: state, initialConfig: initial),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.tap(find.text('国际节点'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    final saved = await tester.runAsync(() => AppConfig.load());
    expect(saved?.relayUrl, intlRelayUrl);
    expect(saved?.deviceToken, 'token');
    expect(saved?.encryptionKey, 'key');
    expect(saved?.modelId, 'model');
    expect(state.connections.last, intlRelayUrl);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

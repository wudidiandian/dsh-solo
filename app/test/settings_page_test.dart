import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dsh_solo/l10n/app_l10n.dart';
import 'package:dsh_solo/relay/relay_client.dart';
import 'package:dsh_solo/state/app_state.dart';
import 'package:dsh_solo/ui/home_page.dart';
import 'package:dsh_solo/ui/settings_page.dart';

void main() {
  setUp(() {
    AppL10n.init('zh');
    PackageInfo.setMockInitialValues(
      appName: 'DSH-SOLO',
      packageName: 'dev.dshsolo.dsh_solo',
      version: '9.8.7',
      buildNumber: '321',
      buildSignature: '',
    );
  });

  testWidgets(
    'settings retains the existing connection setup and QR pairing entry',
    (tester) async {
      final state = AppState();
      await tester.pumpWidget(MaterialApp(home: HomePage(state: state)));
      await tester.tap(find.byIcon(Icons.settings));
      await tester.pumpAndSettle();
      for (final title in ['设备连接', '使用帮助', '隐私与权限', '关于 DSH-SOLO']) {
        expect(find.text(title), findsOneWidget);
      }
      await tester.tap(find.text('设备连接'));
      await tester.pumpAndSettle();
      expect(find.text('连接设置'), findsOneWidget);
      expect(find.text('扫码配对'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('设备连接'), findsOneWidget);
    },
  );

  testWidgets('diagnostics only copies safe version and connection fields', (
    tester,
  ) async {
    final state = AppState()
      ..deviceToken = 'DO-NOT-COPY-TOKEN'
      ..relayUrl = 'wss://private-server.example/ws'
      ..relayError = 'DO-NOT-COPY-ERROR';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPage(state: state, onConfigureConnection: () async {}),
      ),
    );
    await tester.tap(find.text('使用帮助'));
    await tester.pumpAndSettle();
    final button = find.text('复制连接诊断');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(copied, contains('9.8.7 (321)'));
    expect(copied, contains('Relay: idle'));
    expect(copied, isNot(contains('DO-NOT-COPY')));
    expect(copied, isNot(contains('private-server')));
  });

  testWidgets(
    'about uses installed package metadata and exposes license information',
    (tester) async {
      final state = AppState();
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(state: state, onConfigureConnection: () async {}),
        ),
      );
      await tester.tap(find.text('关于 DSH-SOLO'));
      await tester.pumpAndSettle();
      expect(find.text('9.8.7 (321)'), findsOneWidget);
      expect(find.text('https://github.com/wudidiandian/dsh-solo'), findsOneWidget);
      expect(find.text('wudidiandian'), findsOneWidget);
      final licenses = find.text('开源软件许可');
      await tester.scrollUntilVisible(licenses, 200, scrollable: find.descendant(
        of: find.byType(ListView).last, matching: find.byType(Scrollable)).first);
      await tester.tap(licenses);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    },
  );

  testWidgets(
    'settings does not label relay-only connections as desktop connected',
    (tester) async {
      AppL10n.init('en');
      final state = AppState()..relayStatus = RelayStatus.open;
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsPage(state: state, onConfigureConnection: () async {}),
        ),
      );
      expect(find.text('Desktop offline'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
      state.agentOnline = true;
      state.notifyListeners();
      await tester.pump();
      expect(find.text('Connected'), findsOneWidget);
      await tester.tap(find.text('Privacy and permissions'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('end-to-end encryption is not implemented'),
        findsOneWidget,
      );
    },
  );
}

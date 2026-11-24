/// DSH-SOLO 移动端入口。
import 'dart:async' show unawaited;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;

import 'config/app_config.dart';
import 'config/install_guard.dart';
import 'l10n/app_l10n.dart';
import 'state/app_state.dart';
import 'state/notification_service.dart';
import 'ui/home_page.dart';
import 'ui/session_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // iOS Keychain 卸载后残留：新安装先清凭据，再读配置（详见 install_guard）
  await guardFreshInstall();
  AppL10n.init(PlatformDispatcher.instance.locale.languageCode);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['dsh_solo'], await rootBundle.loadString('assets/LICENSE'));
  });
  final cfg = await AppConfig.load();
  final state = AppState();
  await NotificationService.instance.init();
  NotificationService.instance.onOpenSession = (sessionId) {
    navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) => SessionPage(state: state, sessionId: sessionId),
      ),
    );
  };
  runApp(DshSoloApp(state: state, initialConfig: cfg));
}

class DshSoloApp extends StatefulWidget {
  const DshSoloApp({super.key, required this.state, this.initialConfig});

  final AppState state;
  final AppConfig? initialConfig;

  @override
  State<DshSoloApp> createState() => _DshSoloAppState();
}

class _DshSoloAppState extends State<DshSoloApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // iOS 挂起会冻结进程并断开 WebSocket：回前台主动验证/重建链路并补同步
      unawaited(widget.state.onAppResumed());
    } else {
      widget.state.appInBackground = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4D6BFE);
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: AppL10n.i.appTitle,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: HomePage(state: widget.state, initialConfig: widget.initialConfig),
    );
  }
}
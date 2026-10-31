/// DSH-SOLO 移动端入口。
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'l10n/app_l10n.dart';
import 'state/app_state.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppL10n.init(PlatformDispatcher.instance.locale.languageCode);
  final cfg = await AppConfig.load();
  runApp(DshSoloApp(state: AppState(), initialConfig: cfg));
}

class DshSoloApp extends StatelessWidget {
  const DshSoloApp({super.key, required this.state, this.initialConfig});

  final AppState state;
  final AppConfig? initialConfig;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF4D6BFE);
    return MaterialApp(
      title: AppL10n.i.appTitle,
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed), useMaterial3: true),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: HomePage(state: state, initialConfig: initialConfig),
    );
  }
}

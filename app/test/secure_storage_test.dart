import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dsh_solo/config/app_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dsh-secure-store-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final file = File('${dir.path}/dsh_solo_config.json');
    if (await file.exists()) await file.delete();
    await dir.delete();
  });
  test(
    'pairing token and independent encryption key use platform secure storage',
    () async {
      final key = base64UrlEncode(List.filled(32, 7)).replaceAll('=', '');
      final config = AppConfig(
        relayUrl: 'wss://example.invalid/ws',
        deviceToken: 'test-token',
        encryptionKey: key,
        modelId: 'test-model',
      );
      await config.save();
      final saved = await AppConfig.load();
      expect(saved?.encryptionKey, key);
      expect(saved?.deviceToken, 'test-token');
      final secure = await const FlutterSecureStorage().read(
        key: 'dsh_solo_pairing_v2',
      );
      expect(secure, contains(key));
      expect(secure, contains('test-token'));
      expect(await File('${dir.path}/dsh_solo_config.json').exists(), isFalse);
    },
  );
  test('legacy JSON credentials migrate to secure storage and the plaintext file is removed', () async {
    final file = File('${dir.path}/dsh_solo_config.json');
    await file.writeAsString(
      jsonEncode({
        'relayUrl': 'wss://example.invalid/ws',
        'deviceToken': 'LEGACY_SECRET_TOKEN',
        'encryptionKey': 'LEGACY_SECRET_KEY',
      }),
    );
    final config = await AppConfig.load();
    expect(config?.deviceToken, 'LEGACY_SECRET_TOKEN');
    expect(config?.encryptionKey, 'LEGACY_SECRET_KEY');
    expect(await file.exists(), isFalse);
    expect(
      await const FlutterSecureStorage().read(key: 'dsh_solo_pairing_v2'),
      contains('LEGACY_SECRET_KEY'),
    );
    // A previously interrupted cleanup is also retried when secure settings already exist.
    await file.writeAsString('{"deviceToken":"STALE_PLAINTEXT"}');
    expect((await AppConfig.load())?.deviceToken, 'LEGACY_SECRET_TOKEN');
    expect(await file.exists(), isFalse);
  });
}

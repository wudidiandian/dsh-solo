import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dsh_solo/config/install_guard_io.dart';
import 'package:dsh_solo/config/secure_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dsh-install-guard-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => dir.path);
    FlutterSecureStorage.setMockInitialValues({
      workstationsStorageKey: '{"stations":[]}',
      legacyPairingStorageKey: 'legacy',
      deviceIdStorageKey: 'a' * 32,
      notifyPromptStorageKey: '1',
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await dir.delete(recursive: true);
  });

  File marker() => File('${dir.path}/dsh_solo_install_v1');

  test('fresh install wipes residual Keychain credentials and writes marker', () async {
    expect(await marker().exists(), isFalse);
    await guardFreshInstall();
    const storage = FlutterSecureStorage();
    for (final key in residualCredentialKeys) {
      expect(await storage.read(key: key), isNull, reason: key);
    }
    expect(await marker().exists(), isTrue);
  });

  test('existing marker keeps credentials (normal launch / backup restore)', () async {
    await marker().create(recursive: true);
    await guardFreshInstall();
    const storage = FlutterSecureStorage();
    expect(await storage.read(key: workstationsStorageKey), isNotNull);
    expect(await storage.read(key: deviceIdStorageKey), 'a' * 32);
  });

  test('second launch after a fresh install does not wipe again', () async {
    await guardFreshInstall();
    const storage = FlutterSecureStorage();
    await storage.write(key: workstationsStorageKey, value: 'paired');
    await guardFreshInstall();
    expect(await storage.read(key: workstationsStorageKey), 'paired');
  });

  test('wipe failure leaves marker unwritten so next launch retries', () async {
    var wiped = 0;
    var written = 0;
    await expectLater(
      reconcileFreshInstall(
        markerExists: () async => false,
        wipeCredentials: () async {
          wiped++;
          throw StateError('keychain unavailable');
        },
        writeMarker: () async => written++,
      ),
      throwsStateError,
    );
    expect(wiped, 1);
    expect(written, 0);
  });

  test('residual key list covers pairing, device identity and notify prompt', () {
    expect(
      residualCredentialKeys,
      containsAll(<String>[
        workstationsStorageKey,
        legacyPairingStorageKey,
        deviceIdStorageKey,
        notifyPromptStorageKey,
      ]),
    );
  });
}
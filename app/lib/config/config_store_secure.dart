import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'config_store_io.dart'
    if (dart.library.html) 'config_store_web.dart'
    as legacy;

const _key = 'dsh_solo_pairing_v2';
const _storage = FlutterSecureStorage();

Future<Map<String, dynamic>?> loadConfigJson() async {
  final saved = await _storage.read(key: _key);
  if (saved != null) {
    await legacy.deleteLegacyConfig();
    return (jsonDecode(saved) as Map).cast<String, dynamic>();
  }
  final old = await legacy.loadConfigJson();
  if (old == null) return null;
  // Store securely before removing legacy credentials. Never fall back to plaintext writes.
  await saveConfigJson(old);
  return old;
}

Future<void> saveConfigJson(Map<String, dynamic> value) async {
  await _storage.write(key: _key, value: jsonEncode(value));
  await legacy.deleteLegacyConfig();
}

/// Web 平台实现：localStorage 键 `dsh_solo_config`。
import 'dart:convert';
import 'dart:html' as html;

const String configStorageKey = 'dsh_solo_config';

Future<Map<String, dynamic>?> loadConfigJson() async {
  try {
    final s = html.window.localStorage[configStorageKey];
    if (s == null || s.isEmpty) return null;
    final j = jsonDecode(s);
    return j is Map ? j.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

Future<void> deleteLegacyConfig() async {
  html.window.localStorage.remove(configStorageKey);
}

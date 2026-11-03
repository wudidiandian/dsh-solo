/// IO 平台实现：应用文档目录下的 JSON 文件（依赖 path_provider）。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<Map<String, dynamic>?> loadConfigJson() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}dsh_solo_config.json');
    if (!await f.exists()) return null;
    final j = jsonDecode(await f.readAsString());
    return j is Map ? j.cast<String, dynamic>() : null;
  } catch (_) {
    return null;
  }
}

/// Only called after platform secure storage has successfully persisted the settings.
/// Cleanup failures propagate, so an incomplete migration is retried on next load.
Future<void> deleteLegacyConfig() async {
  final dir = await getApplicationDocumentsDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}dsh_solo_config.json');
  if (await file.exists()) await file.delete();
}

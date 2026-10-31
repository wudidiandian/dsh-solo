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

Future<void> saveConfigJson(Map<String, dynamic> j) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}dsh_solo_config.json');
    await f.writeAsString(jsonEncode(j));
  } catch (_) {
    // 写入失败不影响运行（下次仍可手动输入）
  }
}

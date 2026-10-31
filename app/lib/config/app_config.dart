/// 本地配置持久化（relay 地址 + 设备令牌）。
///
/// IO 平台存应用文档目录下的 JSON 文件；Web 平台存 localStorage。
/// 读取失败一律静默返回 null。
import 'config_store.dart';
import 'defaults.dart';

class AppConfig {
  AppConfig({required this.relayUrl, required this.deviceToken, this.modelId});

  String relayUrl;
  String deviceToken;

  /// 手机端选中的模型 id（App 重启后恢复；空 = 用宿主默认模型）
  String? modelId;

  static Future<AppConfig?> load() async {
    try {
      final j = await loadConfigJson();
      if (j == null) return null;
      final url = j['relayUrl']?.toString();
      if (url == null || url.isEmpty) return null;
      // 旧官方地址自动迁移：升级新包后无需重新扫码配对
      final migrated = legacyRelayUrl.isNotEmpty && url == legacyRelayUrl ? defaultRelayUrl : url;
      return AppConfig(
        relayUrl: migrated,
        deviceToken: (j['deviceToken']?.toString().isNotEmpty ?? false)
            ? j['deviceToken'].toString()
            : '',
        modelId: j['modelId']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save() => saveConfigJson({
        'relayUrl': relayUrl,
        'deviceToken': deviceToken,
        if (modelId != null) 'modelId': modelId,
      });
}

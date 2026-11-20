/// 本地配置持久化（relay 地址 + 设备令牌 + 加密密钥 + 设备身份）。
///
/// 多工作站：每个 AppConfig 对应一台电脑的配对，经 workstation_store
/// 存入系统安全存储；load() 返回当前活动工作站，save() 原位更新或新建。
import 'defaults.dart';
import 'workstation_store.dart';

class AppConfig {
  AppConfig({
    required this.relayUrl,
    required this.deviceToken,
    this.modelId,
    this.encryptionKey,
    this.stationId,
    this.stationName,
    this.deviceId,
    this.deviceRegistered = false,
  });

  String relayUrl;
  String deviceToken;
  String? encryptionKey;

  /// 手机端选中的模型 id（App 重启后恢复；空 = 用宿主默认模型）
  String? modelId;

  /// 所属工作站 id / 显示名（null = 尚未入库，save 时新建）
  String? stationId;
  String? stationName;

  /// 本手机在该工作站上的设备身份（32 位 hex，首次配对时生成并持久化）
  String? deviceId;

  /// 是否已领取设备专属密钥（true 时 encryptionKey 为设备密钥而非 QR 主密钥）
  bool deviceRegistered;

  Map<String, dynamic> toJson() => {
    'relayUrl': relayUrl,
    'deviceToken': deviceToken,
    if (encryptionKey != null) 'encryptionKey': encryptionKey,
    if (modelId != null) 'modelId': modelId,
    if (deviceId != null) 'deviceId': deviceId,
    if (deviceRegistered) 'deviceRegistered': true,
  };

  static AppConfig? fromJson(Map<String, dynamic> j) {
    final url = j['relayUrl']?.toString();
    if (url == null || url.isEmpty) return null;
    return AppConfig(
      relayUrl: url,
      deviceToken: (j['deviceToken']?.toString().isNotEmpty ?? false)
          ? j['deviceToken'].toString()
          : '',
      modelId: j['modelId']?.toString(),
      encryptionKey: j['encryptionKey']?.toString(),
      deviceId: j['deviceId']?.toString(),
      deviceRegistered: j['deviceRegistered'] == true,
    );
  }

  static Future<AppConfig?> load() async {
    try {
      final ws = await loadWorkstations();
      final active = ws.active;
      if (active == null) return null;
      final config = active.config;
      // 旧官方地址自动迁移：升级新包后无需重新扫码配对
      // An address used as an available international node is ambiguous: it may
      // be an intentional selection from an older version, so preserve it.
      if (legacyRelayUrl.isNotEmpty &&
          legacyRelayUrl != intlRelayUrl &&
          config.relayUrl == legacyRelayUrl) {
        config.relayUrl = defaultRelayUrl;
      }
      config.stationId = active.id;
      config.stationName = active.name;
      return config;
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    await upsertWorkstation(this);
  }
}
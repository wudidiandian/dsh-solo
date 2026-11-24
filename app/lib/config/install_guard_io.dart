/// IO 平台实现：新安装检测 + 残留凭据清理。
///
/// iOS 的 Keychain 在 App 卸载后**不会**被删除，而沙盒文件会随卸载一起删除。
/// 因此用沙盒里的标记文件判断"是否新安装"：标记缺失 => 清空安全存储中的
/// 配对/设备/通知凭据，避免卸载重装后带着旧配对与旧设备身份自动连接。
/// Android 卸载本就清空安全存储，此逻辑等价于无操作；从备份整机恢复时
/// 标记与凭据一起恢复，不会误清。
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'secure_keys.dart';

const _markerName = 'dsh_solo_install_v1';

/// 核心逻辑（依赖注入，便于测试）：
/// 标记存在 => 直接返回；缺失 => 先清凭据再写标记（清理失败不写标记，下次重试）。
Future<void> reconcileFreshInstall({
  required Future<bool> Function() markerExists,
  required Future<void> Function() wipeCredentials,
  required Future<void> Function() writeMarker,
}) async {
  if (await markerExists()) return;
  await wipeCredentials();
  await writeMarker();
}

/// 启动早期调用（AppConfig.load 之前）。任何失败都不阻塞启动。
Future<void> guardFreshInstall() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final marker = File('${dir.path}${Platform.pathSeparator}$_markerName');
    const storage = FlutterSecureStorage();
    await reconcileFreshInstall(
      markerExists: marker.exists,
      wipeCredentials: () async {
        for (final key in residualCredentialKeys) {
          await storage.delete(key: key);
        }
      },
      writeMarker: () async {
        await marker.create(recursive: true);
      },
    );
  } catch (_) {
    /* 清理失败不阻塞启动；下次启动重试 */
  }
}
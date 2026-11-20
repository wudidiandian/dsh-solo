/// 多工作站安全存储：一个工作站 = 一台电脑的配对（地址/令牌/加密密钥/设备身份）。
///
/// 存储键 dsh_solo_workstations_v1；旧版单配对（dsh_solo_pairing_v2）首次读取时
/// 自动迁移为第一个工作站，迁移后删除旧键。
import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_config.dart';
import 'config_store_io.dart'
    if (dart.library.html) 'config_store_web.dart'
    as legacy;

const _key = 'dsh_solo_workstations_v1';
const _legacyKey = 'dsh_solo_pairing_v2';
const _storage = FlutterSecureStorage();

class WorkstationEntry {
  WorkstationEntry({required this.id, required this.config, this.name = ''});

  final String id;
  String name;
  AppConfig config;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'config': config.toJson(),
  };

  static WorkstationEntry? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final config = AppConfig.fromJson(
      (j['config'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    if (id == null || id.isEmpty || config == null) return null;
    final name = j['name']?.toString() ?? '';
    // 回填工作站身份：切换后保存必须原位更新，而不是新建条目
    config.stationId = id;
    config.stationName = name;
    return WorkstationEntry(id: id, name: name, config: config);
  }
}

class Workstations {
  Workstations({this.activeId, List<WorkstationEntry>? stations})
    : stations = stations ?? [];

  String? activeId;
  List<WorkstationEntry> stations;

  WorkstationEntry? get active {
    for (final s in stations) {
      if (s.id == activeId) return s;
    }
    return stations.isEmpty ? null : stations.first;
  }
}

String newStationId() =>
    'ws-${List.generate(8, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

const _deviceIdKey = 'dsh_solo_device_id_v1';
final _deviceIdPattern = RegExp(r'^[0-9a-f]{32}$');

String newDeviceId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// 本手机的全局设备身份：一个 App 安装一个 id，所有工作站共用。
/// 同一手机重复扫同一台电脑时插件注册幂等（不新建设备条目）；
/// 撤销设备即撤销它在该电脑上的全部配对。
/// 迁移：老版本按工作站各自生成过 id，取第一个既有 id 作为全局 id，避免重复条目。
Future<String> ensureDeviceId() async {
  try {
    final saved = await _storage.read(key: _deviceIdKey);
    if (saved != null && _deviceIdPattern.hasMatch(saved)) return saved;
  } catch (_) {}
  String? id;
  try {
    final ws = await loadWorkstations();
    for (final s in ws.stations) {
      final d = s.config.deviceId;
      if (d != null && _deviceIdPattern.hasMatch(d)) {
        id = d;
        break;
      }
    }
  } catch (_) {}
  id ??= newDeviceId();
  try {
    await _storage.write(key: _deviceIdKey, value: id);
  } catch (_) {}
  return id;
}

Future<Workstations> loadWorkstations() async {
  try {
    final saved = await _storage.read(key: _key);
    if (saved != null) {
      final j = (jsonDecode(saved) as Map).cast<String, dynamic>();
      final stations = ((j['stations'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => WorkstationEntry.fromJson(e.cast<String, dynamic>()))
          .whereType<WorkstationEntry>()
          .toList();
      // 清理可能残留的旧版凭据（上次迁移中断等场景），失败下次加载重试
      try {
        await _storage.delete(key: _legacyKey);
        await legacy.deleteLegacyConfig();
      } catch (_) {}
      final ws = Workstations(activeId: j['activeId']?.toString(), stations: stations);
      // 同一台电脑（deviceToken 相同）只保留一个工作站：历史重复条目合并到活动项
      if (_dedupeByToken(ws)) await saveWorkstations(ws);
      return ws;
    }
  } catch (_) {
    return Workstations();
  }
  // 旧版单配对迁移
  try {
    final oldRaw = await _storage.read(key: _legacyKey);
    final old = oldRaw != null
        ? (jsonDecode(oldRaw) as Map).cast<String, dynamic>()
        : await legacy.loadConfigJson();
    if (old != null) {
      final config = AppConfig.fromJson(old);
      if (config != null) {
        final ws = Workstations(
          activeId: 'ws-legacy',
          stations: [WorkstationEntry(id: 'ws-legacy', config: config)],
        );
        await saveWorkstations(ws);
        await _storage.delete(key: _legacyKey);
        await legacy.deleteLegacyConfig();
        return ws;
      }
    }
  } catch (_) {
    /* 迁移失败按无配置处理 */
  }
  return Workstations();
}

Future<void> saveWorkstations(Workstations ws) async {
  await _storage.write(
    key: _key,
    value: jsonEncode({
      'activeId': ws.activeId,
      'stations': [for (final s in ws.stations) s.toJson()],
    }),
  );
}

/// 合并 deviceToken 相同的重复工作站（保留活动项，否则保留第一条）。
/// 返回是否发生了合并。令牌为空的未配对条目不参与去重。
bool _dedupeByToken(Workstations ws) {
  final seen = <String, WorkstationEntry>{};
  final kept = <WorkstationEntry>[];
  var changed = false;
  for (final s in ws.stations) {
    final token = s.config.deviceToken;
    if (token.isEmpty) {
      kept.add(s);
      continue;
    }
    final first = seen[token];
    if (first == null) {
      seen[token] = s;
      kept.add(s);
      continue;
    }
    changed = true;
    // 活动项优先保留：把它的配置/名字换到保留位
    if (s.id == ws.activeId) {
      final i = kept.indexOf(first);
      kept[i] = s;
      seen[token] = s;
    }
  }
  if (changed) {
    ws.stations = kept;
    if (ws.activeId != null && !kept.any((s) => s.id == ws.activeId)) {
      ws.activeId = kept.firstOrNull?.id;
    }
  }
  return changed;
}

/// 保存一个工作站配置：无 stationId 则新建并设为当前；有则原位更新。
/// 新配对若扫到已存在的电脑（deviceToken 相同），更新该工作站而非新建条目。
Future<AppConfig> upsertWorkstation(AppConfig config) async {
  final ws = await loadWorkstations();
  var id = config.stationId;
  if (id == null || id.isEmpty) {
    final token = config.deviceToken;
    final existing = token.isEmpty
        ? null
        : ws.stations.where((s) => s.config.deviceToken == token).firstOrNull;
    if (existing != null) {
      id = existing.id;
      config.stationId = id;
      config.stationName = existing.name;
    } else {
      id = newStationId();
      config.stationId = id;
    }
  }
  final i = ws.stations.indexWhere((s) => s.id == id);
  if (i >= 0) {
    ws.stations[i].config = config;
    if (config.stationName != null && config.stationName!.isNotEmpty) {
      ws.stations[i].name = config.stationName!;
    }
  } else {
    ws.stations.add(
      WorkstationEntry(id: id, name: config.stationName ?? '', config: config),
    );
  }
  ws.activeId = id;
  await saveWorkstations(ws);
  return config;
}
/// 本地系统通知：App 退到后台时，任务完成 / 待审批等事件弹系统通知。
///
/// 权限采用上下文化请求：首次连上电脑后由 App 内说明卡片引导用户主动开启
/// （见 home_page），而非冷启动盲弹系统框；被永久拒绝后可跳转系统设置。
/// 依赖进程存活（WebSocket 仍在收事件）；进程被系统杀死后的真正离线推送
/// 需要 FCM / 厂商通道，属后续工作。Web 平台不支持，全部静默跳过。
import 'package:app_settings/app_settings.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _promptKey = 'dsh_solo_notify_prompt_v1';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// 点击通知打开对应会话（main.dart 注入导航回调）
  void Function(String sessionId)? onOpenSession;

  Future<void> init() async {
    if (kIsWeb || _ready) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // iOS 不在初始化时盲弹权限框，跟随上下文化请求时机
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (response) {
          final sid = response.payload;
          if (sid != null && sid.isNotEmpty) onOpenSession?.call(sid);
        },
      );
      _ready = true;
    } catch (_) {
      /* 通知初始化失败不影响主链路 */
    }
  }

  /// 是否已展示过开启引导（一次性，拒绝后不再打扰）
  Future<bool> get promptShown async {
    try {
      return await const FlutterSecureStorage().read(key: _promptKey) != null;
    } catch (_) {
      return true;
    }
  }

  Future<void> markPromptShown() async {
    try {
      await const FlutterSecureStorage().write(key: _promptKey, value: '1');
    } catch (_) {}
  }

  /// 系统层通知是否已允许（Android 12- 默认允许；读取失败按未开启处理）
  Future<bool> notificationsEnabled() async {
    if (kIsWeb) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) return await android.areNotificationsEnabled() ?? false;
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        final p = await ios.checkPermissions();
        return p?.isEnabled ?? false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 请求系统通知权限（仅在用户于引导卡片/设置中主动开启时调用）
  Future<bool> requestPermission() async {
    if (kIsWeb || !_ready) return false;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        return await android.requestNotificationsPermission() ?? false;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        return await ios.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 系统层已永久拒绝（或用户想手动关闭）时跳转系统通知设置
  Future<void> openSystemSettings() async {
    if (kIsWeb) return;
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    } catch (_) {}
  }

  Future<void> show({
    required String title,
    required String body,
    String? sessionId,
    bool high = false,
  }) async {
    if (kIsWeb || !_ready) return;
    try {
      final android = AndroidNotificationDetails(
        'dsh_solo_events',
        'DSH-SOLO',
        channelDescription: '任务完成与审批提醒 / Task and approval alerts',
        importance: high ? Importance.max : Importance.high,
        priority: high ? Priority.max : Priority.high,
      );
      await _plugin.show(
        sessionId == null ? 0 : sessionId.hashCode & 0x7fffffff,
        title,
        body,
        NotificationDetails(
          android: android,
          iOS: const DarwinNotificationDetails(),
        ),
        payload: sessionId,
      );
    } catch (_) {}
  }
}
/// DSH-SOLO 统一报文协议 (Envelope Protocol) v1 —— Dart 端实现。
///
/// 字段与三端契约保持一致：
/// - TS 契约源：packages/protocol/src/index.ts
/// - Go 端：server/internal/proto
/// 所有 JSON 字段均为小驼峰（camelCase）。
import 'dart:convert';
import 'dart:math';

/// 协议版本号
const int protocolVersion = 1;

/// 报文类型常量
class MsgType {
  static const helloAgent = 'hello.agent';
  static const helloMobile = 'hello.mobile';
  static const helloOk = 'hello.ok';
  static const helloError = 'hello.error';
  static const agentSnapshot = 'agent.snapshot';
  static const sessionEvent = 'session.event';
  // 逐字流（2026-10-28）：瞬时帧，不入历史缓冲，断线即丢
  static const sessionStream = 'session.stream';
  static const syncRequest = 'sync.request';
  static const syncCatchup = 'sync.catchup';
  static const cmdDispatch = 'cmd.dispatch';
  static const rpcResponse = 'rpc.response';
}

/// 推送优先级常量
const String pushNone = 'none';
const String pushNormal = 'normal';
const String pushHigh = 'high';

/// 远程指令 action 常量
class CmdAction {
  static const sessionPrompt = 'session.prompt';
  static const approvalRespond = 'approval.respond';
  static const fsListDir = 'fs.list_dir';
  static const sessionRename = 'session.rename';
  static const sessionDelete = 'session.delete';
  static const sessionHistory = 'session.history';

  /// 文件上传（2026-10-28）：手机 → 电脑，relay 字节限流、agent 内存组装落盘
  static const fileOffer = 'file.offer';
  static const fileChunk = 'file.chunk';
}

/// 统一 JSON 报文信封
class Envelope {
  /// 协议版本，固定为 1
  final int v;

  /// 报文类型
  final String type;

  /// RPC 关联 ID（cmd.dispatch / rpc.response 成对出现）
  final String? reqId;

  /// 所属会话 ID
  final String? sessionId;

  /// 会话内严格单调递增的序列号（session.event 必填）
  final int? seqId;

  /// 推送优先级
  final String? pushLevel;

  /// 推送摘要（手机离线时展示在系统通知里）
  final String? pushSummary;

  /// 毫秒时间戳
  final int? ts;

  /// 业务负载
  final Object? payload;

  const Envelope({
    this.v = protocolVersion,
    required this.type,
    this.reqId,
    this.sessionId,
    this.seqId,
    this.pushLevel,
    this.pushSummary,
    this.ts,
    this.payload,
  });

  factory Envelope.fromJson(Map<String, dynamic> j) => Envelope(
        v: (j['v'] as num?)?.toInt() ?? protocolVersion,
        type: j['type'] as String,
        reqId: j['reqId'] as String?,
        sessionId: j['sessionId'] as String?,
        seqId: (j['seqId'] as num?)?.toInt(),
        pushLevel: j['pushLevel'] as String?,
        pushSummary: j['pushSummary'] as String?,
        ts: (j['ts'] as num?)?.toInt(),
        payload: j['payload'],
      );

  Map<String, dynamic> toJson() => {
        'v': v,
        'type': type,
        if (reqId != null) 'reqId': reqId,
        if (sessionId != null) 'sessionId': sessionId,
        if (seqId != null) 'seqId': seqId,
        if (pushLevel != null) 'pushLevel': pushLevel,
        if (pushSummary != null) 'pushSummary': pushSummary,
        if (ts != null) 'ts': ts,
        if (payload != null) 'payload': payload,
      };

  /// payload 以 Map 形式访问（非 Map 时返回空表）
  Map<String, dynamic> get payloadMap =>
      payload is Map ? Map<String, dynamic>.from(payload as Map) : const <String, dynamic>{};
}

int _idCounter = 0;
final Random _random = Random();

/// 生成 RPC 关联 ID
String newId() {
  _idCounter++;
  final t = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final r = _random.nextInt(0x7FFFFFFF).toRadixString(36).padLeft(7, '0');
  return 'id-$t-$_idCounter-$r';
}

/// 构造一个符合协议的信封
///
/// [extra] 支持 reqId / sessionId / seqId / pushLevel / pushSummary。
Envelope makeEnvelope(String type, [Object? payload, Map<String, Object?> extra = const {}]) {
  return Envelope(
    type: type,
    ts: DateTime.now().millisecondsSinceEpoch,
    payload: payload,
    reqId: extra['reqId'] as String?,
    sessionId: extra['sessionId'] as String?,
    seqId: extra['seqId'] as int?,
    pushLevel: extra['pushLevel'] as String?,
    pushSummary: extra['pushSummary'] as String?,
  );
}

/// 序列化为 JSON 文本
String encodeEnvelope(Envelope e) => jsonEncode(e.toJson());

/// 安全解析：非法报文返回 null（不抛异常，保证连接层健壮性）
Envelope? tryDecodeEnvelope(String raw) {
  try {
    final j = jsonDecode(raw);
    if (j is Map<String, dynamic> && j['type'] is String) {
      return Envelope.fromJson(j);
    }
  } catch (_) {
    // 忽略非 JSON / 非法报文
  }
  return null;
}

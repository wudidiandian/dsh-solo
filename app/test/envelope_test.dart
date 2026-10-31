/// 协议层测试：信封序列化 / 解析健壮性 / ID 生成
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/protocol/envelope.dart';

void main() {
  group('Envelope', () {
    test('toJson 字段为 camelCase 且版本为 1', () {
      final env = makeEnvelope(MsgType.cmdDispatch, {'action': 'fs.list_dir', 'data': {'path': '/tmp'}},
          {'reqId': 'req-1', 'sessionId': 's1'});
      final j = jsonDecode(encodeEnvelope(env)) as Map<String, dynamic>;

      expect(j['v'], protocolVersion);
      expect(j['type'], 'cmd.dispatch');
      expect(j['reqId'], 'req-1');
      expect(j['sessionId'], 's1');
      expect(j.containsKey('seqId'), isFalse); // 未设置的字段不序列化
      expect(j.containsKey('ts'), isTrue);
      expect((j['payload'] as Map)['action'], 'fs.list_dir');
    });

    test('fromJson / toJson 往返一致', () {
      final env = makeEnvelope(
        MsgType.sessionEvent,
        {'kind': 'text.delta', 'text': '你好'},
        {'sessionId': 's1', 'seqId': 3, 'pushLevel': 'normal', 'pushSummary': '摘要'},
      );
      final back = Envelope.fromJson(jsonDecode(encodeEnvelope(env)) as Map<String, dynamic>);

      expect(back.type, env.type);
      expect(back.sessionId, 's1');
      expect(back.seqId, 3);
      expect(back.pushLevel, 'normal');
      expect(back.pushSummary, '摘要');
      expect((back.payload as Map)['text'], '你好');
    });

    test('tryDecodeEnvelope 对非法报文返回 null 而不抛异常', () {
      expect(tryDecodeEnvelope('not-json'), isNull);
      expect(tryDecodeEnvelope('{"no-type": 1}'), isNull);
      expect(tryDecodeEnvelope('[1,2,3]'), isNull);
      expect(tryDecodeEnvelope('{"type":"hello.ok"}'), isNotNull);
    });

    test('payloadMap 对非 Map payload 安全返回空表', () {
      const env = Envelope(type: 'x', payload: 'plain');
      expect(env.payloadMap, isEmpty);
    });

    test('newId 唯一性', () {
      final ids = {for (var i = 0; i < 1000; i++) newId()};
      expect(ids.length, 1000);
    });
  });
}

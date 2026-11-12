import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dsh_solo/state/session_cache_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'history JSON round-trips through background encoding and decoding',
    () async {
      final dir = await Directory.systemTemp.createTemp('dsh-cache-test-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => dir.path);
      try {
        final events = [
          for (var i = 1; i <= 300; i++)
            <String, dynamic>{
              'seqId': i,
              'kind': 'assistant/message',
              'data': {'text': '中文🚀 $i ' * 100},
            },
        ];
        await saveSessionCache('background-test', 300, events);
        // The public cache API debounces writes; wait for its atomic JSON payload.
        final file = File('${dir.path}/dsh_history/background-test.json');
        for (var i = 0; i < 100; i++) {
          if (await file.exists() && await file.length() > 0) {
            final cached = await loadSessionCache('background-test');
            if (cached != null) {
              expect(cached.lastSeqId, 300);
              expect(cached.events, events);
              return;
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
        fail('Background cache write did not finish');
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      }
    },
  );
}

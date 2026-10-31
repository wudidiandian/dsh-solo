/// IO platform implementation: one JSON file per session under
/// `<getApplicationDocumentsDirectory()>/dsh_history/`. Writes are debounced
/// per session and rewrite the whole file (events are capped well below a
/// size that would matter). All failures are silently ignored — the cache is
/// a pure optimization and must never block the UI.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'session_cache.dart';

const String _cacheDirName = 'dsh_history';
const Duration _debounceInterval = Duration(milliseconds: 300);

/// sessionId → pending write timer (whole-file rewrite debounce)
final Map<String, Timer> _pendingWrites = {};

/// sessionId → latest data waiting to be flushed
final Map<String, Map<String, dynamic>> _pendingData = {};

/// Strip characters that are unsafe in file names.
String _safeName(String sessionId) =>
    sessionId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');

Future<File?> _cacheFile(String sessionId) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return File(
      '${dir.path}${Platform.pathSeparator}$_cacheDirName'
      '${Platform.pathSeparator}${_safeName(sessionId)}.json',
    );
  } catch (_) {
    return null;
  }
}

Future<CachedSession?> loadSessionCache(String sessionId) async {
  try {
    final f = await _cacheFile(sessionId);
    if (f == null || !await f.exists()) return null;
    final j = jsonDecode(await f.readAsString());
    if (j is! Map) return null;
    final rawEvents = (j['events'] as List? ?? const []);
    return CachedSession(
      lastSeqId: (j['lastSeqId'] as num?)?.toInt() ?? 0,
      events: [
        for (final e in rawEvents)
          if (e is Map) Map<String, dynamic>.from(e),
      ],
    );
  } catch (_) {
    return null;
  }
}

Future<void> saveSessionCache(
  String sessionId,
  int lastSeqId,
  List<Map<String, dynamic>> events,
) async {
  // Coalesce rapid saves: only the latest data per session is flushed.
  _pendingData[sessionId] = {'lastSeqId': lastSeqId, 'events': events};
  _pendingWrites[sessionId]?.cancel();
  _pendingWrites[sessionId] = Timer(_debounceInterval, () async {
    final data = _pendingData.remove(sessionId);
    _pendingWrites.remove(sessionId);
    if (data == null) return;
    try {
      final f = await _cacheFile(sessionId);
      if (f == null) return;
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(data));
    } catch (_) {
      // Cache write failure is non-fatal
    }
  });
}

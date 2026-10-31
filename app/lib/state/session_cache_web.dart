/// Web platform implementation: in-memory only (no persistence available),
/// keeps the same interface so callers are platform-agnostic.
import 'session_cache.dart';

final Map<String, CachedSession> _memoryStore = {};

Future<CachedSession?> loadSessionCache(String sessionId) async {
  return _memoryStore[sessionId];
}

Future<void> saveSessionCache(
  String sessionId,
  int lastSeqId,
  List<Map<String, dynamic>> events,
) async {
  _memoryStore[sessionId] = CachedSession(lastSeqId: lastSeqId, events: events);
}

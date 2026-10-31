/// Session event cache backend conditional export:
/// VM/Android persist to local files (IO impl), Web keeps memory-only.
export 'session_cache_io.dart' if (dart.library.html) 'session_cache_web.dart';

/// Events cached for one session, keyed by seqId ordering.
class CachedSession {
  /// Highest seqId persisted; used as the incremental sync cursor.
  final int lastSeqId;

  /// Raw session event objects (each embeds its seqId), oldest first.
  final List<Map<String, dynamic>> events;

  const CachedSession({required this.lastSeqId, required this.events});
}

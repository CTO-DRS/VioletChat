import '../storage/local_database.dart';

/// v0.1.13 — view-once media registry (وسائط الرؤية الواحدة).
///
/// The `once` flag itself travels INSIDE the ciphertext (MediaInfo.once)
/// — the server only ever sees kind='media'. What this class adds is the
/// LOCAL "already viewed" bookkeeping: a `vo:<messageId>` key in the
/// device's kv table. After the first view the receiver's client:
///   1. marks the message viewed here (survives app restarts),
///   2. wipes the decrypted media payload from messages_cache
///      (MessageCache.applyOnceViewed — blob key included),
///   3. renders a tombstone bubble instead of the content,
///   4. excludes the row from the in-chat media gallery.
///
/// Nothing about this is server-visible: the encrypted blob stays on
/// storage (unreadable to the server), and the receiver's copy becomes
/// unrenderable on their own device. This is an honest client-side
/// privacy contract — like every E2E system, the viewer can always
/// photograph the screen; what we guarantee is the app never keeps or
/// re-serves the media after the first view.
class ViewOnce {
  ViewOnce._();

  static const String _prefix = 'vo:';

  /// kv key for a viewed once-media message.
  static String key(String messageId) => '$_prefix$messageId';

  /// All message ids already viewed on THIS device.
  static Future<Set<String>> viewedIds() async {
    final map = await LocalDatabase.kvByPrefix(_prefix);
    return {
      for (final k in map.keys)
        if (k.length > _prefix.length) k.substring(_prefix.length),
    };
  }

  /// Has THIS device already viewed [messageId]?
  static Future<bool> isViewed(String messageId) async =>
      await LocalDatabase.kvGet(key(messageId)) != null;

  /// Persist the first (and only) view. Idempotent — calling twice is
  /// harmless (the UI layer short-circuits anyway).
  static Future<void> markViewed(String messageId) =>
      LocalDatabase.kvSet(key(messageId), '1');
}

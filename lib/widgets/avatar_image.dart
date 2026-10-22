import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// In-memory avatar bytes cache (v0.1.0).
///
/// Key = the storage path of the avatar (avatars/{uid}/avatar_{ts}.jpg).
/// Every new upload produces a NEW timestamped path, so a changed
/// profile picture naturally invalidates the cache on every device —
/// no TTL needed. The map lives for the app session only; avatars are
/// small (a resized 512px JPEG is ~100KB), and the number of distinct
/// profiles per session is bounded by the user's chats.
class AvatarImageCache {
  AvatarImageCache._();

  static final Map<String, Uint8List> _mem = {};

  /// In-flight download dedup: several widgets showing the same profile
  /// (chat list + app bar + profile screen) must not trigger parallel
  /// downloads of the same object.
  static final Map<String, Future<Uint8List?>> _pending = {};

  /// Returns avatar bytes for [path], or null when the object cannot be
  /// fetched (deleted, no permission, offline). Null is NOT cached —
  /// a later retry (e.g. after reconnect) gets another chance.
  static Future<Uint8List?> load(String path) async {
    final hit = _mem[path];
    if (hit != null) return hit;

    final existing = _pending[path];
    if (existing != null) return existing;

    final fut = _download(path);
    _pending[path] = fut;
    try {
      return await fut;
    } finally {
      _pending.remove(path);
    }
  }

  static Future<Uint8List?> _download(String path) async {
    try {
      final bytes =
          await Supabase.instance.client.storage.from('avatars').download(path);
      final u = Uint8List.fromList(bytes);
      if (u.isEmpty) return null;
      _mem[path] = u;
      return u;
    } catch (_) {
      return null;
    }
  }
}

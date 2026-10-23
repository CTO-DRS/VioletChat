import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/local_database.dart';
import '../data/models/models.dart';
import '../services/story_service.dart';
import 'app_services.dart';
import 'auth_controller.dart';

/// v0.1.10 — stories ring state (حالات الأصدقاء).
///
/// Cache-light controller: the ring is fetched fresh (24h-lived server
/// rows, decrypt-on-read), grouped by author, and «seen» state lives in
/// the local encrypted kv — mirrors WhatsApp ring semantics without a
/// server-side per-user view pointer.
class StoriesController extends ChangeNotifier {
  final AppServices services;
  final AuthController auth;
  StoriesController(this.services, this.auth);

  /// Ring entries grouped by author, ascending by created_at inside
  /// each group. Includes ME (key = my user id).
  Map<String, List<StoryItem>> byAuthor = {};

  /// Story ids already opened on THIS device (local, kv-persisted).
  Set<String> viewed = {};

  bool loading = false;
  String? error;

  /// Author id -> profile (names/avatars for the ring + viewer).
  /// Populated on every refresh for all ring authors.
  Map<String, Profile> profileCache = {};

  Timer? _timer;

  static const String _viewedKey = 'stories:viewed:v1';
  static const int _viewedCap = 500;

  String get myId => services.auth.userId ?? '';

  /// Authors with live stories, newest-first (me first, then by newest).
  List<String> get authorOrder {
    final entries = byAuthor.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => (
              id: e.key,
              newest: e.value
                  .map((s) => s.createdAtDate)
                  .reduce((a, b) => a.isAfter(b) ? a : b)
            ))
        .toList()
      ..sort((a, b) => b.newest.compareTo(a.newest));
    final meFirst = entries.where((e) => e.id == myId).toList();
    final rest = entries.where((e) => e.id != myId).toList();
    return [...meFirst, ...rest.map((e) => e.id)];
  }

  bool get hasUnseen =>
      byAuthor.entries.any((e) =>
          e.key != myId && e.value.any((s) => !viewed.contains(s.id)));

  bool authorHasUnseen(String authorId) =>
      authorId != myId &&
      (byAuthor[authorId]?.any((s) => !viewed.contains(s.id)) ?? false);

  Future<void> start() async {
    await _loadViewed();
    unawaited(refresh());
    // Opportunistic refresh — stories live 24h; every 5 minutes while
    // the app is open is plenty (no realtime channel needed).
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), () {
      if (auth.signedIn) unawaited(refresh());
    });
  }

  Future<void> _loadViewed() async {
    try {
      final raw = await LocalDatabase.kvGet(_viewedKey);
      if (raw != null && raw.isNotEmpty) {
        viewed = (jsonDecode(raw) as List).map((e) => '$e').toSet();
      }
    } catch (_) {}
  }

  Future<void> _persistViewed() async {
    try {
      final list = viewed.toList();
      if (list.length > _viewedCap) {
        list.removeRange(0, list.length - _viewedCap);
        viewed = list.toSet();
      }
      await LocalDatabase.kvSet(_viewedKey, jsonEncode(list));
    } catch (_) {}
  }

  /// Rebuild the ring. Friends = direct-chat peers from the local chat
  /// cache (the same definition the server RLS uses: an existing
  /// direct chat between the two accounts).
  Future<void> refresh() async {
    if (!auth.signedIn) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final chats = await services.cache.chats();
      final friends = <String>{};
      for (final c in chats) {
        if (!c.isGroup && c.peer != null) friends.add(c.peer!.id);
      }
      final ring = await services.stories.fetchRing(friends.toList());
      final map = <String, List<StoryItem>>{};
      for (final s in ring) {
        if (s.isExpired) continue;
        (map[s.authorId] ??= []).add(s);
      }
      for (final l in map.values) {
        l.sort((a, b) => a.createdAtDate.compareTo(b.createdAtDate));
      }
      byAuthor = map;
      // Names + avatars for the ring (best-effort — initials fallback).
      try {
        final authors = {
          myId,
          ...map.keys,
        };
        final fresh = await services.stories.profilesOf(authors);
        if (fresh.isNotEmpty) {
          profileCache = {...profileCache, ...fresh};
        }
      } catch (_) {}
    } catch (e) {
      error = 'تعذر تحميل الحالات';
      AppLogger.w('stories', 'refresh failed', e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Text status (imageBytes null) or an encrypted image story.
  Future<bool> publish({
    String? text,
    Uint8List? imageBytes,
    int? width,
    int? height,
  }) async {
    if (!auth.signedIn) return false;
    if ((text == null || text.trim().isEmpty) && imageBytes == null) {
      return false;
    }
    try {
      final chats = await services.cache.chats();
      final friends = <String>{
        for (final c in chats)
          if (!c.isGroup && c.peer != null) c.peer!.id,
      };
      final item = await services.stories.publish(
        friendIds: friends.toList(),
        text: text,
        imageBytes: imageBytes,
        width: width,
        height: height,
      );
      (byAuthor[myId] ??= []).add(item);
      notifyListeners();
      return true;
    } catch (e) {
      AppLogger.w('stories', 'publish failed', e);
      return false;
    }
  }

  /// Local ring flip + server view receipt. Never fatal.
  Future<void> markViewed(StoryItem s) async {
    if (viewed.add(s.id)) {
      notifyListeners();
      await _persistViewed();
    }
    try {
      await services.stories.markViewed(s.id);
    } catch (_) {}
  }

  /// Author-only delete (server RLS enforces).
  Future<void> deleteStory(StoryItem s) async {
    try {
      await services.stories.deleteStory(s);
    } catch (e) {
      AppLogger.w('stories', 'delete failed', e);
    }
    final list = byAuthor[s.authorId];
    if (list != null) {
      byAuthor[s.authorId] = list.where((x) => x.id != s.id).toList();
      if (byAuthor[s.authorId]!.isEmpty) byAuthor.remove(s.authorId);
    }
    notifyListeners();
    unawaited(refresh());
  }

  /// Viewers of MY stories (storyId -> userId -> viewedAt).
  Future<Map<String, Map<String, String>>> myViewers() async {
    final mine = byAuthor[myId] ?? const <StoryItem>[];
    try {
      return await services.stories
          .viewers(mine.map((s) => s.id).toList());
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, Profile>> profilesOf(Set<String> ids) async {
    try {
      return await services.stories.profilesOf(ids);
    } catch (_) {
      return {};
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

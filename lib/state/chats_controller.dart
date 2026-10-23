import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/constants/app_constants.dart';
import '../core/storage/local_database.dart';
import '../core/storage/message_cache.dart';
import '../data/models/models.dart';
import 'app_services.dart';
import 'auth_controller.dart';

/// Chats list state: cache-first, live updates, unread counts,
/// notifications for new incoming messages.
class ChatsController extends ChangeNotifier {
  final AppServices services;
  final AuthController auth;
  ChatsController(this.services, this.auth);

  List<Chat> chats = [];
  Map<String, Message> previews = {};
  Map<String, int> unread = {};

  /// v0.1.0: per-chat unsent drafts (chatId -> plain text), read from
  /// the encrypted local kv store; surfaced as "مسودة" in the list.
  Map<String, String> drafts = {};

  bool loading = false;
  bool online = true;
  StreamSubscription? _subs;

  Future<void> start() async {
    await load();
    services.connectivity.changes.listen((o) {
      online = o;
      notifyListeners();
    });
    _subs = services.realtime.messageEvents.listen(_onMessageEvent);
    services.realtime.chatEvents.listen((_) => load());
    services.realtime.receiptEvents.listen((_) async {
      unread = await _safeUnread();
      notifyListeners();
    });
  }

  Future<void> load() async {
    loading = true;
    notifyListeners();
    try {
      // 1) instant cache
      chats = await services.cache.chats();
      await _loadPreviews();
      unawaited(_loadDrafts());
      notifyListeners();
      // 2) fresh server
      if (services.auth.isSignedIn) {
        final fresh = await services.chats.loadMyChats();
        chats = fresh;
        for (final c in fresh) {
          await services.cache.upsertChat(c);
        }
        unread = await _safeUnread();
        await _loadPreviews();
        await _loadDrafts();
      }
    } catch (_) {
      // offline: keep cache
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _loadDrafts() async {
    try {
      final blobs = await LocalDatabase.kvByPrefix('draft:');
      final out = <String, String>{};
      for (final e in blobs.entries) {
        final chatId = e.key.substring('draft:'.length);
        final json = await LocalDatabase.openJson(e.value);
        final text = (json?['t'] as String? ?? '').trim();
        if (text.isNotEmpty) out[chatId] = text;
      }
      drafts = out;
      notifyListeners();
    } catch (_) {
      // Draft previews are cosmetic — ignore failures.
    }
  }

  Future<void> _loadPreviews() async {
    final map = <String, Message>{};
    for (final c in chats) {
      final last = await services.cache.lastForChat(c.id);
      if (last != null) map[c.id] = last;
    }
    previews = map;
  }

  Future<Map<String, int>> _safeUnread() async {
    try {
      return await services.messages.unreadCounts();
    } catch (_) {
      return {};
    }
  }

  Future<void> _onMessageEvent(Map<String, dynamic> row) async {
    try {
      await services.sync.onRealtimeRow(row);
      final chatId = row['chat_id'] as String?;
      final senderId = row['sender_id'] as String?;
      if (chatId == null || senderId == null) return;
      final isMine = senderId == MessageCache.myId;
      if (!isMine) {
        unread[chatId] = (unread[chatId] ?? 0) + 1;
        final chat = chats.where((c) => c.id == chatId).firstOrNull;
        final m = await services.cache.lastForChat(chatId);
        if (m != null) previews[chatId] = m;
        // v0.1.10: encrypted ballots never ring — they are tallied
        // silently inside the poll bubble (unread badge still counts).
        final isBallot = m?.kind == AppConstants.kindPollVote;
        if (chat != null && !isBallot) {
          // v0.1.0: muted chats keep receiving messages silently —
          // no notification, no sound, unread badge still applies.
          if (!chat.isMuted) {
            await services.notifications.showMessageNotification(
              chatTitle: chat.title,
              previewText: m?.text,
              isGroup: chat.isGroup,
              chatId: chat.id,
            );
          }
        }
      } else {
        final m = await services.cache.lastForChat(chatId);
        if (m != null) previews[chatId] = m;
      }
      notifyListeners();
    } catch (e) {
      // decryption failures surface inside the chat screen instead
    }
  }

  /// Create (or fetch) a direct chat and return its id.
  Future<String> openDirectChat(String otherUserId) =>
      services.chats.getOrCreateDirectChat(otherUserId);

  /// v0.1.0: flip MY OWN per-chat flags (pin / mute / archive).
  /// Optimistic locally, then persisted via the set_chat_flags RPC;
  /// on RPC failure the local state stays (next load() re-syncs the
  /// truth from the server) and the error propagates to the caller.
  Future<void> setChatFlags(
    Chat chat, {
    bool? pinned,
    bool? muted,
    bool? archived,
  }) async {
    // Sentinel dance: null = leave untouched, true = set, false = clear.
    final nowIso = DateTime.now().toUtc().toIso8601String();
    final inTenYears = DateTime.now()
        .toUtc()
        .add(const Duration(days: 3650))
        .toIso8601String();
    final pinnedAt = pinned == null
        ? Chat.flagUnset
        : (pinned ? nowIso : null as Object?);
    final mutedUntil = muted == null
        ? Chat.flagUnset
        : (muted ? inTenYears : null as Object?);
    final archivedAt = archived == null
        ? Chat.flagUnset
        : (archived ? nowIso : null as Object?);
    final i = chats.indexWhere((c) => c.id == chat.id);
    if (i != -1) {
      chats = [...chats]..[i] = chats[i].copyWithFlags(
          pinnedAt: pinnedAt,
          mutedUntil: mutedUntil,
          archivedAt: archivedAt,
        );
      await services.cache.upsertChat(chats[i]);
      notifyListeners();
    }
    await services.chats.setChatFlags(chat.id,
        pinned: pinned, muted: muted, archived: archived);
  }

  /// v0.1.0: chats with the archived flag (rendered in their own
  /// section behind the «المؤرشفة» entry, never in the main list).
  List<Chat> get archivedChats =>
      chats.where((c) => c.isArchived).toList();

  Future<void> deleteChatLocally(Chat c) async {
    await services.cache.removeChat(c.id);
    await services.cache.deleteChat(c.id);
    if (c.isGroup && c.myRole == 'owner') {
      try {
        await services.chats.deleteGroup(c.id);
      } catch (_) {}
    }
    await load();
  }

  @override
  void dispose() {
    _subs?.cancel();
    super.dispose();
  }
}

extension _FirstOrNullX<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

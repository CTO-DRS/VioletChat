import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/models.dart';

/// Messages: cursor pagination, sends, receipts, reactions,
/// edits, deletes.
class MessageRepository {
  final SupabaseClient client;
  MessageRepository(this.client);

  String get myId => client.auth.currentUser!.id;

  /// Cursor pagination — oldest page first:
  /// fetch messages older than [beforeIso] (null = latest page).
  /// v0.1.0: selects expires_at (disappearing messages).
  Future<List<Map<String, dynamic>>> fetchMessages({
    required String chatId,
    String? beforeIso,
    String? afterIso,
    int limit = 30,
  }) async {
    var q = client
        .from('messages')
        .select(
            'id, chat_id, sender_id, sender_device_id, client_msg_id, kind, body, reply_to, forwarded_from, edited_at, deleted_for_all_at, expires_at, created_at')
        .eq('chat_id', chatId);

    if (beforeIso != null) {
      q = q.lt('created_at', beforeIso);
    } else if (afterIso != null) {
      q = q.gt('created_at', afterIso);
    }

    final rows = await q
        .order(beforeIso != null ? 'created_at' : 'created_at',
            ascending: beforeIso != null)
        .limit(limit);
    final list = (rows as List).cast<Map<String, dynamic>>();
    // Always return ascending by created_at.
    list.sort((a, b) =>
        (a['created_at'] as String).compareTo(b['created_at'] as String));
    return list;
  }

  /// Insert a message. Uses client_msg_id for idempotency — the
  /// unique index on (sender_id, client_msg_id) prevents duplicates
  /// when a queued message is retried after a timeout.
  Future<Map<String, dynamic>?> insertMessage(Map<String, dynamic> row) async {
    try {
      final res = await client.from('messages').insert(row).select().single();
      return res;
    } on PostgrestException catch (e) {
      // Unique violation => already inserted by a previous attempt.
      if (e.code == '23505') return null;
      rethrow;
    }
  }

  /// Edit my message body (re-encrypted). Server validates sender
  /// only via trigger, and only body/edited_at may change.
  Future<void> editMessage(String messageId, Map<String, dynamic> body) =>
      client
          .from('messages')
          .update({
            'body': body,
            'edited_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', messageId)
          .eq('sender_id', myId);

  /// Delete for everyone (sender only).
  Future<void> deleteForEveryone(String messageId) => client
      .from('messages')
      .update({
        'deleted_for_all_at': DateTime.now().toUtc().toIso8601String(),
        'body': {'v': 1, 't': 's', 'sd': '', 'sys': ''}
      })
      .eq('id', messageId)
      .eq('sender_id', myId);

  /// Delete for me (hide locally + server-side hide row).
  Future<void> deleteForMe(String messageId) =>
      client.from('message_hides').insert({'message_id': messageId});

  Future<List<String>> hiddenMessageIds(String chatId) async {
    // FIX (audit 2026-10-25): filter by chat — the old version ignored
    // its parameter and returned EVERY hide row across ALL chats.
    final rows = await client
        .from('message_hides')
        .select('message_id, messages!inner(chat_id)')
        .eq('messages.chat_id', chatId);
    return (rows as List).map((e) => e['message_id'] as String).toList();
  }

  // ------------------------------------------------------------------
  // Receipts
  // ------------------------------------------------------------------
  /// Bulk mark delivered for all incoming messages of a chat up to now.
  Future<void> markDelivered(String chatId) =>
      client.rpc('mark_messages_delivered', params: {'p_chat_id': chatId});

  /// Bulk mark read.
  Future<void> markRead(String chatId) =>
      client.rpc('mark_messages_read', params: {'p_chat_id': chatId});

  /// Receipts of OTHER members for messages I sent (ticks).
  Future<List<Receipt>> fetchReceipts(String chatId) async {
    final rows = await client
        .from('message_receipts')
        .select('message_id, user_id, delivered_at, read_at')
        .inFilter(
            'message_id',
            (await client
                    .from('messages')
                    .select('id')
                    .eq('chat_id', chatId)
                    .eq('sender_id', myId)
                    .order('created_at', ascending: false)
                    .limit(200) as List)
                .map((e) => e['id'] as String)
                .toList());
    return (rows as List)
        .map((r) => Receipt.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------------
  // Reactions
  // ------------------------------------------------------------------
  Future<void> react(String messageId, String emoji) async {
    if (emoji.isEmpty) {
      await client
          .from('message_reactions')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', myId);
    } else {
      await client.from('message_reactions').upsert({
        'message_id': messageId,
        'user_id': myId,
        'emoji': emoji,
      });
    }
  }

  Future<List<Reaction>> fetchReactions(String chatId) async {
    final rows = await client
        .from('message_reactions')
        .select('message_id, user_id, emoji, created_at')
        .eq('chat_id', chatId);
    return (rows as List)
        .map((r) => Reaction.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------------
  // Pinning
  // ------------------------------------------------------------------
  Future<void> setPinned(String messageId, bool pinned) =>
      client.from('messages').update({
        'pinned_at': pinned ? DateTime.now().toUtc().toIso8601String() : null
      }).eq('id', messageId);

  /// v0.1.0: the currently pinned message of a chat (sender-pinned via
  /// messages_guard). Returns the raw row so the caller can decrypt it
  /// through the normal merge path. At most one is surfaced — the
  /// most recently pinned.
  Future<Map<String, dynamic>?> fetchPinned(String chatId) async {
    final rows = await client
        .from('messages')
        .select(
            'id, chat_id, sender_id, sender_device_id, client_msg_id, kind, body, reply_to, forwarded_from, edited_at, deleted_for_all_at, expires_at, created_at')
        .eq('chat_id', chatId)
        .not('pinned_at', 'is', null)
        .order('pinned_at', ascending: false)
        .limit(1);
    return (rows as List).isEmpty ? null : rows.first;
  }

  // ------------------------------------------------------------------
  // Unread counts (server computed, RLS-safe)
  // ------------------------------------------------------------------
  Future<Map<String, int>> unreadCounts() async {
    final res = await client.rpc('get_unread_counts') as List;
    final out = <String, int>{};
    for (final r in res) {
      final m = r as Map<String, dynamic>;
      out[m['chat_id'] as String] = (m['unread'] as num).toInt();
    }
    return out;
  }

  /// Server messages created after [afterIso] (catch-up sync).
  Future<List<Map<String, dynamic>>> fetchSince(
      String chatId, String afterIso) async {
    final rows = await client
        .from('messages')
        .select(
            'id, chat_id, sender_id, sender_device_id, client_msg_id, kind, body, reply_to, forwarded_from, edited_at, deleted_for_all_at, expires_at, created_at')
        .eq('chat_id', chatId)
        .gt('created_at', afterIso)
        .order('created_at')
        .limit(200);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  // ------------------------------------------------------------------
  // v0.1.0 — disappearing messages
  // ------------------------------------------------------------------
  /// Flip the chat's disappearing TTL. [seconds] null/0 = OFF.
  Future<void> setDisappearTtl(String chatId, int? seconds) =>
      client.rpc('set_disappear_ttl', params: {
        'p_chat_id': chatId,
        'p_ttl_seconds': (seconds == null || seconds <= 0) ? 0 : seconds,
      });

  /// Server-side GC for expired messages of one chat (children rows
  /// cascade). Returns the number of deleted messages.
  Future<int> purgeExpired(String chatId) async {
    final res = await client
        .rpc('purge_expired_messages', params: {'p_chat_id': chatId});
    return (res as num?)?.toInt() ?? 0;
  }

  // ------------------------------------------------------------------
  // v0.1.0 — starred messages (server rows; local cache mirrors)
  // ------------------------------------------------------------------
  Future<void> toggleStar(String messageId, bool star) async {
    if (star) {
      await client.from('message_stars').upsert({
        'message_id': messageId,
        'user_id': myId,
      });
    } else {
      await client
          .from('message_stars')
          .delete()
          .eq('message_id', messageId)
          .eq('user_id', myId);
    }
  }

  /// My starred rows across chats (server source of truth). The UI
  /// reads the decrypted local cache — this is used to re-sync flags.
  Future<List<String>> starredIds() async {
    final res = await client.rpc('get_starred_messages') as List;
    return res
        .map((e) => (e as Map<String, dynamic>)['id'] as String)
        .toList();
  }
}

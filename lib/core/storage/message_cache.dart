import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../config/app_config.dart';
import '../utils/message_search.dart';
import 'local_database.dart';
import '../../data/models/models.dart';

/// Local CRUD over messages_cache / chats_cache / receipts / reactions.
/// All writes happen through here so cache invariants stay consistent.
///
/// SECURITY (audit 2026-10-25): every CONTENT column (text,
/// media_json, body_json, reply_preview) is SEALED at rest via
/// LocalDatabase.sealText — the raw SQLite file no longer holds
/// readable message content. Legacy rows written by older builds are
/// unmarked plaintext and pass through openText untouched, so the
/// upgrade needs no migration or cache wipe.
class MessageCache {
  const MessageCache();

  /// Set by the auth flow so cache rows know which rows are mine.
  static String? myId;

  // ------------------------------------------------------------------
  // Messages
  // ------------------------------------------------------------------
  Future<void> upsertMessage(Message m) async {
    final db = await LocalDatabase.instance;
    await db.insert(
      'messages_cache',
      await _toRow(m),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertMessages(List<Message> list) async {
    if (list.isEmpty) return;
    final db = await LocalDatabase.instance;
    final batch = db.batch();
    for (final m in list) {
      batch.insert('messages_cache', await _toRow(m),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> updateState(
      String clientMsgId, MsgState state, String? failureReason,
      {String? realId, String? serverAt}) async {
    final db = await LocalDatabase.instance;
    await db.update(
      'messages_cache',
      {
        'state': state.name,
        'failure_reason': failureReason,
        if (realId != null) 'id': realId,
        if (serverAt != null) 'server_at': serverAt,
      },
      where: 'client_msg_id = ?',
      whereArgs: [clientMsgId],
    );
  }

  Future<void> markDeletedForAll(String messageId) async {
    final db = await LocalDatabase.instance;
    await db.update(
      'messages_cache',
      {'deleted_for_all': 1, 'text': null, 'media_json': null},
      where: 'id = ? OR client_msg_id = ?',
      whereArgs: [messageId, messageId],
    );
  }

  Future<void> applyEdit(String messageId, String? text) async {
    final db = await LocalDatabase.instance;
    await db.update(
      'messages_cache',
      {
        'text': await LocalDatabase.sealText(text),
        'edited_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? OR client_msg_id = ?',
      whereArgs: [messageId, messageId],
    );
  }

  /// v0.1.11 — replace a cached poll body after an edit (question,
  /// options) + stamp edited_at. The pollId is untouched, so existing
  /// ballots keep counting (PollTally links via pollRef).
  Future<void> applyPollEdit(String messageId, PollInfo poll) async {
    final db = await LocalDatabase.instance;
    await db.update(
      'messages_cache',
      {
        'text': await LocalDatabase.sealText(poll.question),
        'body_json':
            await LocalDatabase.sealText(jsonEncode({'poll': poll.toJson()})),
        'edited_at': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ? OR client_msg_id = ?',
      whereArgs: [messageId, messageId],
    );
  }

  /// v0.1.13 — view-once media was just viewed on THIS device: drop
  /// the decrypted media payload (blob key + nonce included) from the
  /// local cache. The row itself survives (ordering, caption, meta),
  /// but the content can never be re-rendered — the bubble shows a
  /// tombstone, the gallery excludes the row, and the encrypted blob
  /// key no longer sits in the device database.
  Future<void> applyOnceViewed(String messageId) async {
    final db = await LocalDatabase.instance;
    await db.update(
      'messages_cache',
      {'media_json': null},
      where: 'id = ? OR client_msg_id = ?',
      whereArgs: [messageId, messageId],
    );
  }

  /// Cursor pagination — [beforeIso] null => latest page.
  /// Returns ASC order (oldest -> newest).
  Future<List<Message>> page(String chatId, {String? beforeIso}) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query(
      'messages_cache',
      where: 'chat_id = ?'
          '${beforeIso != null ? ' AND created_at < ?' : ''}',
      whereArgs: beforeIso != null ? [chatId, beforeIso] : [chatId],
      orderBy: 'created_at DESC',
      limit: AppConfig.pageSize,
    );
    final out = <Message>[];
    for (final r in rows) {
      final m = await _fromRow(r);
      if (m != null) out.add(m);
    }
    return out.reversed.toList();
  }

  // ------------------------------------------------------------------
  // v0.1.0 — starred messages (local view of message_stars)
  // ------------------------------------------------------------------
  Future<List<Message>> starred({int limit = 500}) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where: 'starred = 1 AND deleted_for_all = 0',
        orderBy: 'created_at DESC',
        limit: limit);
    return _decodeAll(rows);
  }

  Future<void> setStarred(String messageId, bool on) async {
    final db = await LocalDatabase.instance;
    await db.update('messages_cache', {'starred': on ? 1 : 0},
        where: 'id = ? OR client_msg_id = ?',
        whereArgs: [messageId, messageId]);
  }

  // ------------------------------------------------------------------
  // v0.1.0 — local GC for expired (disappearing) messages. The server
  // purge RPC is the source of truth; this only trims the cache.
  // ------------------------------------------------------------------
  Future<int> purgeExpired({String? chatId}) async {
    final db = await LocalDatabase.instance;
    return db.delete('messages_cache',
        where:
            'expires_at IS NOT NULL AND expires_at <= ?${chatId != null ? ' AND chat_id = ?' : ''}',
        whereArgs:
            chatId != null ? [nowIso(), chatId] : [nowIso()]);
  }

  static String nowIso() => DateTime.now().toUtc().toIso8601String();

  /// v0.1.0 — all cached messages of a chat (ASC), for chat export.
  /// Bound by [limit] so a decade-long chat cannot blow the heap.
  Future<List<Message>> allForChat(String chatId, {int limit = 2000}) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where: 'chat_id = ?',
        whereArgs: [chatId],
        orderBy: 'created_at ASC',
        limit: limit);
    return _decodeAll(rows);
  }

  /// v0.1.0 — cached media rows of a chat (newest first), for the
  /// in-chat media gallery.
  /// v0.1.13 — view-once rows are EXCLUDED from the gallery for
  /// everyone (sender included): the gallery is a persistent surface,
  /// and once-media must never live outside the chat transcript.
  Future<List<Message>> media(String chatId, {int limit = 300}) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where:
            'chat_id = ? AND kind = ? AND deleted_for_all = 0 AND media_json IS NOT NULL',
        whereArgs: [chatId, 'media'],
        orderBy: 'created_at DESC',
        limit: limit);
    final out = <Message>[];
    for (final m in await _decodeAll(rows)) {
      // A row whose sealed media_json fails to open renders without its
      // payload — it must not reach the gallery either.
      if (m.media == null) continue;
      if (!m.media!.once) out.add(m);
    }
    return out;
  }

  /// v0.1.13 — in-chat search over the decrypted local cache
  /// (البحث داخل المحادثة). Scans EVERY cached row of the chat — not
  /// just the loaded window — with the tolerant Arabic normalization
  /// (messageMatchesQuery), and returns matches oldest → newest.
  /// The server stores none of this text (E2E); search is a purely
  /// local capability.
  Future<List<Message>> searchInChat(String chatId, String rawQuery,
      {int limit = 200}) async {
    final q = rawQuery.trim();
    if (q.isEmpty) return [];
    final db = await LocalDatabase.instance;
    final rows = await db.query(
      'messages_cache',
      where: 'chat_id = ? AND deleted_for_all = 0',
      whereArgs: [chatId],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    final out = <Message>[];
    for (final m in await _decodeAll(rows)) {
      if (messageMatchesQuery(m, q)) out.add(m);
    }
    return out;
  }

  /// Global search over ALL cached messages (newest first).
  ///
  /// Was a SQL `LIKE` over the text column; that column is SEALED at
  /// rest now, so LIKE cannot see plaintext. This scans recent rows and
  /// filters in Dart with the SAME tolerant Arabic normalisation as the
  /// in-chat search — strictly better matching than the old raw LIKE.
  /// Bounded to the 2000 most recent rows so a decade-long cache cannot
  /// blow the heap.
  Future<List<Message>> search(String query, {int limit = 50}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final db = await LocalDatabase.instance;
    final rows = await db.query(
      'messages_cache',
      where: 'deleted_for_all = 0',
      orderBy: 'created_at DESC',
      limit: 2000,
    );
    final out = <Message>[];
    for (final m in await _decodeAll(rows)) {
      if (messageMatchesQuery(m, q)) {
        out.add(m);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  Future<Message?> byId(String id) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where: 'id = ? OR client_msg_id = ?', whereArgs: [id, id]);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<Message?> lastForChat(String chatId) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where: 'chat_id = ? AND deleted_for_all = 0',
        whereArgs: [chatId],
        orderBy: 'created_at DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Future<String?> latestServerAt(String chatId) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('messages_cache',
        where: 'chat_id = ? AND server_at != ?',
        whereArgs: [chatId, ''],
        orderBy: 'server_at DESC',
        limit: 1);
    if (rows.isEmpty) return null;
    return rows.first['server_at'] as String?;
  }

  Future<void> deleteForMe(String messageId) async {
    final db = await LocalDatabase.instance;
    await db.delete('messages_cache',
        where: 'id = ? OR client_msg_id = ?',
        whereArgs: [messageId, messageId]);
  }

  Future<void> deleteChat(String chatId) async {
    final db = await LocalDatabase.instance;
    await db
        .delete('messages_cache', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  // ------------------------------------------------------------------
  // Chats cache
  // ------------------------------------------------------------------
  Future<void> upsertChat(Chat c) async {
    final db = await LocalDatabase.instance;
    await db.insert(
      'chats_cache',
      {
        'id': c.id,
        'title': c.title,
        'json': jsonEncode(_chatJson(c)),
        'updated_at':
            c.lastMessageAt ?? DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Chat>> chats() async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('chats_cache', orderBy: 'updated_at DESC');
    return rows
        .map((r) {
          try {
            return Chat.fromJson(
                jsonDecode(r['json'] as String) as Map<String, dynamic>, '');
          } catch (_) {
            return null;
          }
        })
        .whereType<Chat>()
        .toList();
  }

  Future<void> removeChat(String chatId) async {
    final db = await LocalDatabase.instance;
    await db.delete('chats_cache', where: 'id = ?', whereArgs: [chatId]);
  }

  // ------------------------------------------------------------------
  // Receipts & reactions
  // ------------------------------------------------------------------
  Future<void> upsertReceipt(Receipt r) async {
    final db = await LocalDatabase.instance;
    await db.insert(
        'receipts_cache',
        {
          'message_id': r.messageId,
          'user_id': r.userId,
          'delivered_at': r.deliveredAt,
          'read_at': r.readAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Receipt>> receipts(List<String> messageIds) async {
    if (messageIds.isEmpty) return [];
    final db = await LocalDatabase.instance;
    final rows = await db.query('receipts_cache',
        where:
            'message_id IN (${List.filled(messageIds.length, '?').join(',')})',
        whereArgs: messageIds);
    return rows
        .map((r) => Receipt(r['message_id'] as String, r['user_id'] as String,
            r['delivered_at'] as String?, r['read_at'] as String?))
        .toList();
  }

  Future<void> upsertReaction(Reaction r) async {
    final db = await LocalDatabase.instance;
    if (r.emoji.isEmpty) {
      await db.delete('reactions_cache',
          where: 'message_id = ? AND user_id = ?',
          whereArgs: [r.messageId, r.userId]);
      return;
    }
    await db.insert(
        'reactions_cache',
        {
          'message_id': r.messageId,
          'user_id': r.userId,
          'emoji': r.emoji,
          'created_at': r.createdAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Reaction>> reactions(List<String> messageIds) async {
    if (messageIds.isEmpty) return [];
    final db = await LocalDatabase.instance;
    final rows = await db.query('reactions_cache',
        where:
            'message_id IN (${List.filled(messageIds.length, '?').join(',')})',
        whereArgs: messageIds);
    return rows
        .map((r) => Reaction(r['message_id'] as String, r['user_id'] as String,
            r['emoji'] as String, r['created_at'] as String))
        .toList();
  }

  // ------------------------------------------------------------------
  // Serialisation (content columns sealed at rest)
  // ------------------------------------------------------------------
  Future<Map<String, Object?>> _toRow(Message m) async => {
        'id': m.id,
        'chat_id': m.chatId,
        'sender_id': m.senderId,
        'client_msg_id': m.clientMsgId,
        'kind': m.kind,
        'text': await LocalDatabase.sealText(m.text),
        'media_json': m.media == null
            ? null
            : await LocalDatabase.sealText(jsonEncode(m.media!.toJson())),
        // v0.1.10: poll body / ballot index ride the (previously unused)
        // body_json column — no schema migration needed.
        'body_json': await LocalDatabase.sealText(_pollJson(m)),
        'reply_to': m.replyTo,
        'reply_preview': await LocalDatabase.sealText(m.replyPreview),
        'forwarded_from': m.forwardedFrom,
        'expires_at': m.expiresAt,
        'starred': m.starred ? 1 : 0,
        'created_at': m.createdAt,
        'server_at': m.serverAt,
        'edited_at': m.editedAt,
        'deleted_for_all': m.isDeletedForAll ? 1 : 0,
        'key_version': m.keyVersion,
        'state': m.localState.name,
        'failure_reason': m.failureReason,
        'decrypted': m.decrypted ? 1 : 0,
        'outgoing': (myId != null && m.senderId == myId) ? 1 : 0,
      };

  /// v0.1.10: decrypted poll payloads for the local cache. The local
  /// DB is already encrypted at rest (LocalDatabase seal), same trust
  /// level as the rest of the cached message content.
  /// v0.1.12: location ('loc') and contact cards ('card') ride the
  /// same column — no schema migration.
  String? _pollJson(Message m) {
    final hasStoryRef = m.storyRef != null;
    final hasLoc = m.location != null;
    final hasCard = m.contact != null;
    if (m.poll != null || hasLoc || hasCard) {
      return jsonEncode({
        if (m.poll != null) 'poll': m.poll!.toJson(),
        if (hasLoc) 'loc': m.location!.toJson(),
        if (hasCard) 'card': m.contact!.toJson(),
        if (m.pollVote != null) 'vote': m.pollVote,
        if (m.pollRef != null) 'ref': m.pollRef,
        if (hasStoryRef) 'sref': m.storyRef,
      });
    }
    if (m.pollVote != null || m.pollRef != null || hasStoryRef) {
      return jsonEncode({
        if (m.pollVote != null) 'vote': m.pollVote,
        if (m.pollRef != null) 'ref': m.pollRef,
        if (hasStoryRef) 'sref': m.storyRef,
      });
    }
    return null;
  }

  Future<Message?> _fromRow(Map<String, Object?> r) async {
    try {
      final mediaJson =
          await LocalDatabase.openText(r['media_json'] as String?);
      final pollJson = await LocalDatabase.openText(r['body_json'] as String?);
      final text = await LocalDatabase.openText(r['text'] as String?);
      final replyPreview =
          await LocalDatabase.openText(r['reply_preview'] as String?);
      PollInfo? poll;
      int? pollVote;
      String? pollRef;
      String? storyRef;
      LocationInfo? location;
      ContactInfo? contact;
      if (pollJson != null && pollJson.isNotEmpty) {
        try {
          final j = jsonDecode(pollJson) as Map<String, dynamic>;
          poll = PollInfo.fromJson(j['poll'] as Map<String, dynamic>?);
          pollVote = (j['vote'] as num?)?.toInt();
          pollRef = j['ref'] as String?;
          storyRef = j['sref'] as String?;
          location = LocationInfo.fromJson(j['loc'] as Map<String, dynamic>?);
          contact = ContactInfo.fromJson(j['card'] as Map<String, dynamic>?);
        } catch (_) {}
      }
      return Message(
        id: r['id'] as String,
        chatId: r['chat_id'] as String,
        senderId: r['sender_id'] as String,
        senderDeviceId: '',
        clientMsgId: r['client_msg_id'] as String? ?? r['id'] as String,
        kind: r['kind'] as String? ?? 'text',
        text: text,
        media: mediaJson == null
            ? null
            : MediaInfo.fromJson(jsonDecode(mediaJson) as Map<String, dynamic>),
        poll: poll,
        pollVote: pollVote,
        pollRef: pollRef,
        storyRef: storyRef,
        location: location,
        contact: contact,
        replyTo: r['reply_to'] as String?,
        replyPreview: replyPreview,
        forwardedFrom: r['forwarded_from'] as String?,
        isDeletedForAll: (r['deleted_for_all'] as int? ?? 0) == 1,
        editedAt: r['edited_at'] as String?,
        expiresAt: r['expires_at'] as String?,
        starred: (r['starred'] as int? ?? 0) == 1,
        createdAt: r['created_at'] as String,
        serverAt: r['server_at'] as String? ?? '',
        keyVersion: r['key_version'] as int? ?? 0,
        localState: MsgState.values.firstWhere((s) => s.name == r['state'],
            orElse: () => MsgState.sent),
        failureReason: r['failure_reason'] as String?,
        decrypted: (r['decrypted'] as int? ?? 1) == 1,
      );
    } catch (_) {
      return null;
    }
  }

  /// Decode rows sequentially (sealed columns are opened one by one —
  /// the dbKey is memoised after the first call, so this is cheap).
  Future<List<Message>> _decodeAll(List<Map<String, Object?>> rows) async {
    final out = <Message>[];
    for (final r in rows) {
      final m = await _fromRow(r);
      if (m != null) out.add(m);
    }
    return out;
  }

  Map<String, dynamic> _chatJson(Chat c) => {
        'id': c.id,
        'type': c.type,
        'peer': c.peer == null
            ? null
            : {
                'id': c.peer!.id,
                'username': c.peer!.username,
                'display_name': c.peer!.displayName,
                'avatar_path': c.peer!.avatarPath,
                'bio': c.peer!.bio,
                'created_at': c.peer!.createdAt,
              },
        'name': c.name,
        'description': c.description,
        'avatar_path': c.avatarPath,
        'created_by': c.createdBy,
        'invite_code': c.inviteCode,
        'my_role': c.myRole,
        'created_at': c.createdAt,
        'last_message_at': c.lastMessageAt,
        'my_pinned_at': c.pinnedAt,
        'my_muted_until': c.mutedUntil,
        'my_archived_at': c.archivedAt,
      };
}

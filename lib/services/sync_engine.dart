import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/local_database.dart';
import '../core/storage/message_cache.dart';
import '../data/models/models.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/message_repository.dart';
import 'auth_service.dart';
import 'message_crypto_service.dart';

/// Offline-first engine.
///
///  OUTGOING: send -> persist(cache, state=queued) -> enqueue outbox
///            -> processor drains when online (idempotent: unique
///            client_msg_id server-side, replace locally).
///  RETRY   : exponential backoff 5s..15min, capped attempts -> failed.
///  SYNC    : per-chat cursor (latest server_at) -> fetchSince ->
///            decrypt -> upsert cache. Runs on start / reconnect /
///            explicit refresh.
class SyncEngine {
  final AuthService auth;
  final MessageRepository messages;
  final ChatRepository chats;
  final MessageCryptoService crypto;
  final MessageCache cache;
  final ConnectivityService connectivity;

  final _outboxChanged = StreamController<void>.broadcast();
  Timer? _timer;
  bool _draining = false;

  SyncEngine(this.auth, this.messages, this.chats, this.crypto, this.cache,
      this.connectivity);

  Stream<void> get outboxChanges => _outboxChanged.stream;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => drain());
    connectivity.changes.listen((online) {
      if (online) {
        drain();
        syncAll();
      }
    });
    drain();
    syncAll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // ==================================================================
  // OUTGOING
  // ==================================================================

  /// Queue a new outgoing message. Returns the provisional Message.
  /// [forwardedFrom] (v0.1.0) marks the copy as a forward of another
  /// message: it rides the encrypted inner payload AND the plaintext
  /// forwarded_from column (mirroring the replyTo pattern).
  Future<Message> enqueueText(Chat chat, String text,
      {String? replyTo, String? replyPreview, String? forwardedFrom}) async {
    final clientMsgId = _uuid();
    final inner = {
      'kind': 'text',
      'text': text,
      if (replyTo != null) 'replyTo': replyTo,
      if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
    };
    final m = Message.placeholder(
      clientMsgId: clientMsgId,
      chatId: chat.id,
      senderId: auth.userId!,
      senderDeviceId: crypto.identity.deviceId,
      text: text,
      media: null,
      kind: 'text',
      replyTo: replyTo,
      replyPreview: replyPreview,
    );
    await cache.upsertMessage(m);
    await _enqueue(chat.id, 'send', {
      'client_msg_id': clientMsgId,
      'chat_id': chat.id,
      'kind': 'text',
      'inner': inner,
      'reply_to': replyTo,
      if (forwardedFrom != null) 'forwarded_from': forwardedFrom,
    });
    return m;
  }

  Future<Message> enqueueMedia(Chat chat, MediaInfo media,
      {String? caption,
      String? replyTo,
      String? replyPreview,
      String? forwardedFrom}) async {
    final clientMsgId = _uuid();
    final inner = {
      'kind': 'media',
      'text': caption,
      'media': media.toJson(),
      if (replyTo != null) 'replyTo': replyTo,
      if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
    };
    final m = Message.placeholder(
      clientMsgId: clientMsgId,
      chatId: chat.id,
      senderId: auth.userId!,
      senderDeviceId: crypto.identity.deviceId,
      text: caption,
      media: media,
      kind: 'media',
      replyTo: replyTo,
      replyPreview: replyPreview,
    );
    await cache.upsertMessage(m);
    await _enqueue(chat.id, 'send', {
      'client_msg_id': clientMsgId,
      'chat_id': chat.id,
      'kind': 'media',
      'inner': inner,
      'reply_to': replyTo,
      if (forwardedFrom != null) 'forwarded_from': forwardedFrom,
    });
    return m;
  }

  Future<void> enqueueEdit(
      String messageId, Chat chat, Map<String, dynamic> inner) async {
    await _enqueue(chat.id, 'edit', {
      'message_id': messageId,
      'chat_id': chat.id,
      'inner': inner,
    });
  }

  Future<void> enqueueDelete(String messageId, Chat chat) async {
    await _enqueue(chat.id, 'delete', {
      'message_id': messageId,
      'chat_id': chat.id,
    });
    await cache.markDeletedForAll(messageId);
  }

  Future<void> _enqueue(
      String chatId, String action, Map<String, dynamic> payload) async {
    final db = await LocalDatabase.instance;
    final id =
        '${payload['client_msg_id'] ?? payload['message_id'] ?? _uuid()}';
    await db.insert(
        'outbox',
        {
          'id': id,
          'chat_id': chatId,
          'action': action,
          'payload': await LocalDatabase.sealJson(payload),
          'attempts': 0,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'next_attempt_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    _outboxChanged.add(null);
    drain();
  }

  /// Drain the outbox (idempotent, concurrency-safe).
  Future<void> drain() async {
    if (_draining || !auth.isSignedIn || !connectivity.isOnline) return;
    _draining = true;
    try {
      final db = await LocalDatabase.instance;
      final now = DateTime.now().toUtc().toIso8601String();
      final rows = await db.query('outbox',
          where: 'next_attempt_at <= ?',
          whereArgs: [now],
          orderBy: 'created_at',
          limit: 25);

      for (final row in rows) {
        final action = row['action'] as String;
        final attempts = row['attempts'] as int;
        final payloadJson =
            await LocalDatabase.openJson(row['payload'] as String);
        if (payloadJson == null) {
          await db.delete('outbox', where: 'id = ?', whereArgs: [row['id']]);
          continue;
        }
        try {
          switch (action) {
            case 'send':
              await _processSend(payloadJson);
              break;
            case 'edit':
              final inner = (payloadJson['inner'] as Map<String, dynamic>);
              final body = await crypto.encryptInner(
                  await _chatOf(payloadJson['chat_id'] as String), inner);
              await messages.editMessage(
                  payloadJson['message_id'] as String, body);
              await cache.applyEdit(payloadJson['message_id'] as String,
                  inner['text'] as String?);
              break;
            case 'delete':
              await messages
                  .deleteForEveryone(payloadJson['message_id'] as String);
              await cache
                  .markDeletedForAll(payloadJson['message_id'] as String);
              break;
          }
          await db.delete('outbox', where: 'id = ?', whereArgs: [row['id']]);
          _outboxChanged.add(null);
        } catch (e) {
          final nextAttempts = attempts + 1;
          if (nextAttempts >= 8) {
            await db.update(
              'outbox',
              {
                'attempts': nextAttempts,
                'last_error': 'permanent failure',
                'next_attempt_at': DateTime.now()
                    .toUtc()
                    .add(const Duration(hours: 1))
                    .toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
            await cache.updateState(
                row['id'] as String, MsgState.failed, 'تعذر الإرسال');
          } else {
            final backoff =
                Duration(seconds: (5 * (1 << nextAttempts)).clamp(5, 15 * 60));
            await db.update(
              'outbox',
              {
                'attempts': nextAttempts,
                'last_error': 'retry scheduled',
                'next_attempt_at':
                    DateTime.now().toUtc().add(backoff).toIso8601String(),
              },
              where: 'id = ?',
              whereArgs: [row['id']],
            );
            await cache.updateState(row['id'] as String, MsgState.queued, null);
          }
          AppLogger.w('sync', 'outbox item failed; will retry', e);
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _processSend(Map<String, dynamic> payload) async {
    final chat = await _chatOf(payload['chat_id'] as String);
    final inner = (payload['inner'] as Map<String, dynamic>);
    final clientMsgId = payload['client_msg_id'] as String;

    await cache.updateState(clientMsgId, MsgState.sending, null);

    final body = await crypto.encryptInner(chat, inner);

    final row = {
      'chat_id': chat.id,
      'sender_id': auth.userId!,
      'sender_device_id': crypto.identity.deviceId,
      'client_msg_id': clientMsgId,
      'kind': payload['kind'] as String? ?? 'text',
      'body': body,
      if (payload['reply_to'] != null) 'reply_to': payload['reply_to'],
      if (payload['forwarded_from'] != null)
        'forwarded_from': payload['forwarded_from'],
    };
    final inserted = await messages.insertMessage(row);
    // inserted == null -> duplicate (already on server) — still success.
    final serverAt = DateTime.now().toUtc().toIso8601String();
    await cache.updateState(clientMsgId, MsgState.sent, null,
        realId: inserted?['id'] as String?, serverAt: serverAt);
  }

  Future<Chat> _chatOf(String chatId) async {
    final cached = await cache.chats();
    final found = cached.where((c) => c.id == chatId).toList();
    if (found.isNotEmpty) return found.first;
    final all = await chats.loadMyChats();
    for (final c in all) {
      await cache.upsertChat(c);
    }
    return all.firstWhere((c) => c.id == chatId,
        orElse: () => throw StateError('chat $chatId not accessible'));
  }

  // ==================================================================
  // INCOMING SYNC
  // ==================================================================

  /// Catch-up sync for every cached chat (bounded by cursor).
  Future<void> syncAll() async {
    if (!auth.isSignedIn || !connectivity.isOnline) return;
    try {
      final list = await cache.chats();
      for (final chat in list) {
        await syncChat(chat.id);
      }
    } catch (e) {
      AppLogger.w('sync', 'syncAll failed', e);
    }
  }

  Future<void> syncChat(String chatId) async {
    if (!auth.isSignedIn || !connectivity.isOnline) return;
    try {
      final chat = await _chatOf(chatId);
      final cursor = await cache.latestServerAt(chatId);
      final rows = await messages.fetchSince(chatId, cursor ?? '');
      if (rows.isEmpty) return;
      await _decryptAndStore(chat, rows);
    } catch (e) {
      AppLogger.w('sync', 'syncChat($chatId) failed', e);
    }
  }

  /// Decrypt fresh server rows and merge into local cache.
  Future<List<Message>> _decryptAndStore(
      Chat chat, List<Map<String, dynamic>> rows) async {
    final out = <Message>[];
    for (final row in rows) {
      final bodyRaw = row['body'];
      Map<String, dynamic>? body;
      if (bodyRaw is Map<String, dynamic>) body = bodyRaw;
      if (bodyRaw is String && bodyRaw.isNotEmpty) {
        body = jsonDecode(bodyRaw) as Map<String, dynamic>;
      }
      InnerPayload inner;
      if (body == null) {
        inner = const InnerPayload(kind: 'text', decrypted: false);
      } else {
        inner = await crypto.decryptRow(chat, row['sender_id'] as String, body);
      }

      final isMine = row['sender_id'] == MessageCache.myId;
      final serverCreatedAt = row['created_at'] as String;
      final m = Message(
        id: row['id'] as String,
        chatId: row['chat_id'] as String,
        senderId: row['sender_id'] as String,
        senderDeviceId: (row['sender_device_id'] ?? '') as String,
        clientMsgId: (row['client_msg_id'] ?? row['id']) as String,
        kind: row['kind'] as String? ?? 'text',
        text: inner.text,
        media: inner.media,
        replyTo: (row['reply_to'] ?? inner.replyTo) as String?,
        forwardedFrom:
            (row['forwarded_from'] ?? inner.forwardedFrom) as String?,
        isDeletedForAll: (row['deleted_for_all_at'] as String?) != null,
        editedAt: row['edited_at'] as String?,
        expiresAt: row['expires_at'] as String?,
        createdAt: serverCreatedAt,
        serverAt: serverCreatedAt,
        keyVersion: body == null ? 0 : MessageEnvelopeX.versionOf(body),
        localState: isMine ? MsgState.sent : MsgState.delivered,
        decrypted: inner.decrypted,
      );
      out.add(m);
    }
    await cache.upsertMessages(out);
    return out;
  }

  /// Merge ONE realtime row (new message or update).
  Future<void> onRealtimeRow(Map<String, dynamic> row) async {
    final chatId = row['chat_id'] as String?;
    if (chatId == null) return;
    final chat = await _chatOf(chatId);
    await _decryptAndStore(chat, [row]);
  }

  /// Public merge for pagination (server rows -> cache).
  Future<void> mergeServerRows(
      Chat chat, List<Map<String, dynamic>> rows) async {
    await _decryptAndStore(chat, rows);
  }

  static const Uuid _uuidGen = Uuid();

  static String _uuid() => _uuidGen.v4();
}

/// Envelope version extraction helper (kept here to avoid importing
/// crypto/envelope into the model layer).
class MessageEnvelopeX {
  static int versionOf(Map<String, dynamic> body) =>
      (body['v'] as num?)?.toInt() ?? 0;
}

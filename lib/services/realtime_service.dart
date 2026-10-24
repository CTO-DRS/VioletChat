import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'message_crypto_service.dart';
import 'session_manager.dart';
import 'sync_engine.dart';

/// Realtime layer — Postgres changes + typing broadcasts.
///
/// Design goals (per spec):
///  - user-scoped: RLS ensures only rows of MY chats arrive
///  - recoverable: on every (re)SUBSCRIBED we run a catch-up sync so
///    events missed while disconnected are fetched via cursor sync
class RealtimeService {
  final SupabaseClient client;
  final SyncEngine sync;
  final SessionManager sessions;
  final MessageCryptoService crypto;

  final _messagesCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _receiptsCtrl = StreamController<void>.broadcast();
  final _reactionsCtrl = StreamController<Map<String, dynamic>>.broadcast();
  final _chatsCtrl = StreamController<void>.broadcast();
  final _typingCtrl = StreamController<
      ({String chatId, String userId, bool typing})>.broadcast();

  RealtimeChannel? _dbChannel;
  RealtimeChannel? _typingChannel;
  StreamSubscription? _reconnectSub;

  RealtimeService(this.client, this.sync, this.sessions, this.crypto);

  Stream<Map<String, dynamic>> get messageEvents => _messagesCtrl.stream;
  Stream<void> get receiptEvents => _receiptsCtrl.stream;
  Stream<Map<String, dynamic>> get reactionEvents => _reactionsCtrl.stream;
  Stream<void> get chatEvents => _chatsCtrl.stream;
  Stream<({String chatId, String userId, bool typing})> get typingEvents =>
      _typingCtrl.stream;

  Future<void> start({required Stream<bool> connectivity}) async {
    _openChannels();
    // Re-sync whenever connectivity flips back to online.
    _reconnectSub = connectivity.listen((online) {
      if (online) {
        _openChannels();
        sync.syncAll();
      }
    });
  }

  void _openChannels() {
    _dbChannel ??= _createDbChannel();
    _typingChannel ??= client.channel('typing-${client.auth.currentUser?.id}');
    _typingChannel?.onBroadcast(
      event: 'typing',
      callback: (p) {
        _typingCtrl.add((
          chatId: p['chat_id'] ?? '',
          userId: p['user_id'] ?? '',
          typing: p['typing'] == true,
        ));
      },
    );
    _dbChannel?.subscribe(_onStatus);
    _typingChannel?.subscribe(_onStatus);
  }

  RealtimeChannel _createDbChannel() {
    final ch = client.channel('db-${client.auth.currentUser?.id}');
    void bind(String table, void Function(Map<String, dynamic>) onNew) {
      ch.onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: table,
        callback: (PostgresChangePayload payload) {
          try {
            final row = payload.newRecord;
            if (row.isNotEmpty) onNew(row);
          } catch (e) {
            AppLogger.w('realtime', 'payload handling failed', e);
          }
        },
      );
    }

    bind('messages', (row) => _messagesCtrl.add(row));
    bind('message_receipts', (_) => _receiptsCtrl.add(null));
    bind('message_reactions', (row) => _reactionsCtrl.add(row));
    bind('chats', (_) => _chatsCtrl.add(null));
    bind('chat_members', (_) => _chatsCtrl.add(null));
    return ch;
  }

  void _onStatus(RealtimeSubscribeStatus status, [Object? error]) {
    if (status == RealtimeSubscribeStatus.subscribed) {
      AppLogger.i('realtime', 'subscribed');
      // Resume protocol: authenticate (handled by client) then sync
      // missing events since our local cursors.
      sync.syncAll();
    } else if (status == RealtimeSubscribeStatus.channelError) {
      AppLogger.w('realtime', 'channel error; will resync on reconnect');
    } else if (status == RealtimeSubscribeStatus.timedOut) {
      AppLogger.w('realtime', 'subscription timed out');
    }
  }

  // ------------------------------------------------------------------
  // Typing indicator
  // ------------------------------------------------------------------
  Future<void> sendTyping(String chatId, bool typing) =>
      _typingChannel?.sendBroadcastMessage(event: 'typing', payload: {
        'chat_id': chatId,
        'user_id': client.auth.currentUser?.id,
        'typing': typing,
      }) ??
      Future.value();

  Future<void> stop() async {
    await _reconnectSub?.cancel();
    // FIX (audit 2026-10-25): null-safe — the old `removeChannel(_dbChannel!)`
    // crashed when stop() was called before the channels were opened (or
    // after a failed start).
    final db = _dbChannel;
    final typing = _typingChannel;
    _dbChannel = null;
    _typingChannel = null;
    if (db != null) {
      try {
        await client.removeChannel(db);
      } catch (_) {}
    }
    if (typing != null) {
      try {
        await client.removeChannel(typing);
      } catch (_) {}
    }
  }

  static bool get callsEnabled => AppConfig.enableCalls;
}

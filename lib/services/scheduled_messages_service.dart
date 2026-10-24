import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/key_value_store.dart';
import '../data/models/models.dart';

/// A message the user queued for later sending (v0.1.14).
///
/// HONEST SEMANTICS (documented in the UI): scheduling is device-local.
/// The message is stored encrypted-at-rest (keystore-backed secure
/// storage) on THIS phone and is sent through the normal E2EE send
/// path when its time arrives — while the app is open or alive in the
/// background. If the phone is off / app killed, the message goes out
/// at the first opportunity after the app is next opened. Nothing is
/// uploaded to the server before send time, so the recipient cannot
/// receive it early (E2EE discipline: we never stage ciphertext+delay
/// server-side).
class ScheduledMessage {
  final String id;
  final String chatId;
  final String text;
  final DateTime sendAt;
  final DateTime createdAt;

  /// Reply linkage captured at schedule time (optional).
  final String? replyTo;
  final String? replyPreview;

  const ScheduledMessage({
    required this.id,
    required this.chatId,
    required this.text,
    required this.sendAt,
    required this.createdAt,
    this.replyTo,
    this.replyPreview,
  });

  bool isDueAt(DateTime now) => !now.toUtc().isBefore(sendAt.toUtc());

  Map<String, dynamic> toJson() => {
        'id': id,
        'chat_id': chatId,
        'text': text,
        'send_at': sendAt.toUtc().toIso8601String(),
        'created_at': createdAt.toUtc().toIso8601String(),
        if (replyTo != null) 'reply_to': replyTo,
        if (replyPreview != null) 'reply_preview': replyPreview,
      };

  static ScheduledMessage fromJson(Map<String, dynamic> j) => ScheduledMessage(
        id: j['id'] as String,
        chatId: j['chat_id'] as String,
        text: j['text'] as String,
        sendAt: DateTime.parse(j['send_at'] as String),
        createdAt: DateTime.parse(j['created_at'] as String),
        replyTo: j['reply_to'] as String?,
        replyPreview: j['reply_preview'] as String?,
      );
}

/// Local queue + ticker that fires due messages.
///
/// Wiring is fully injected (no service-locator cycles):
///  - [chatResolver] finds the Chat for a stored id (local chat cache).
///  - [sender] performs the real E2EE send (SyncEngine.enqueueText).
class ScheduledMessagesService extends ChangeNotifier {
  ScheduledMessagesService(this._store);

  final KeyValueStore _store;
  static const _storeKey = 'violet.scheduled.v1';
  static const _storePrefix = 'violet.scheduled';

  List<ScheduledMessage> pending = [];
  Future<Chat?> Function(String chatId)? chatResolver;
  Future<void> Function(ScheduledMessage msg, Chat chat)? sender;

  Timer? _ticker;
  bool _firing = false;
  bool _loaded = false;

  List<ScheduledMessage> get all => List.unmodifiable(pending);

  List<ScheduledMessage> forChat(String chatId) {
    final list =
        pending.where((m) => m.chatId == chatId).toList()
          ..sort((a, b) => a.sendAt.compareTo(b.sendAt));
    return list;
  }

  /// Load the persisted queue and immediately flush anything that came
  /// due while the app was closed (send-at-next-opportunity semantics).
  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = await _store.read(_storeKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .whereType<Map<String, dynamic>>()
            .map(ScheduledMessage.fromJson)
            .toList();
        pending = list;
      }
    } catch (e) {
      AppLogger.w('scheduled', 'queue load failed', e);
      pending = [];
    }
    _loaded = true;
    notifyListeners();
    await fireDue();
  }

  Future<void> add({
    required String chatId,
    required String text,
    required DateTime sendAt,
    String? replyTo,
    String? replyPreview,
  }) async {
    pending = [
      ...pending,
      ScheduledMessage(
        id: DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        chatId: chatId,
        text: text,
        sendAt: sendAt,
        createdAt: DateTime.now().toUtc(),
        replyTo: replyTo,
        replyPreview: replyPreview,
      ),
    ];
    await _persist();
    notifyListeners();
  }

  Future<void> cancel(String id) async {
    pending = pending.where((m) => m.id != id).toList();
    await _persist();
    notifyListeners();
  }

  /// 15 s tick — accurate enough for chat scheduling (the UI shows
  /// minute granularity).
  void startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 15), (_) => fireDue());
  }

  void stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Send every due message whose chat still resolves. Messages whose
  /// chat disappeared (deleted conversation) are dropped silently.
  Future<void> fireDue() async {
    if (_firing || !_loaded || sender == null || chatResolver == null) return;
    final now = DateTime.now();
    final due =
        pending.where((m) => m.isDueAt(now)).toList()
          ..sort((a, b) => a.sendAt.compareTo(b.sendAt));
    if (due.isEmpty) return;
    _firing = true;
    try {
      for (final m in due) {
        final chat = await chatResolver!(m.chatId);
        if (chat == null) {
          pending = pending.where((x) => x.id != m.id).toList();
          await _persist();
          continue;
        }
        try {
          await sender!(m, chat);
          pending = pending.where((x) => x.id != m.id).toList();
          await _persist();
          notifyListeners();
        } catch (e) {
          // Network hiccup — keep queued, the ticker retries.
          AppLogger.w('scheduled', 'send retry later', e);
          break;
        }
      }
    } finally {
      _firing = false;
    }
  }

  /// Sign-out wipe — the messaging keys are destroyed on sign-out, so
  /// queued items must never survive to a different account/device
  /// identity. Mirrors LocalDatabase.wipeAll().
  Future<void> wipe() async {
    pending = [];
    await _store.wipePrefix(_storePrefix);
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await _store.write(
          _storeKey, jsonEncode(pending.map((m) => m.toJson()).toList()));
    } catch (e) {
      AppLogger.w('scheduled', 'persist failed', e);
    }
  }

  @override
  void dispose() {
    stopTicker();
    super.dispose();
  }
}

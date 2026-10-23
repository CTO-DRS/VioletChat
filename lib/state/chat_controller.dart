import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/config/app_config.dart';
import '../core/constants/app_constants.dart';
import '../core/utils/disappearing_policy.dart';
import '../data/models/models.dart';
import '../services/media_service.dart';
import 'app_services.dart';

/// One chat screen state: paginated messages, sending, receipts,
/// reactions, typing, realtime merge.
class ChatController extends ChangeNotifier {
  final AppServices services;
  final Chat chat;
  ChatController(this.services, this.chat);

  List<Message> messages = [];

  /// v0.1.10: transcript view — encrypted ballots (kind pollVote) are
  /// synced and cached like any message (they drive the tally) but are
  /// never rendered as chat rows.
  List<Message> get chatMessages =>
      messages.where((m) => m.kind != AppConstants.kindPollVote).toList();
  Map<String, List<Reaction>> reactionsByMsg = {};
  Map<String, List<Receipt>> receiptsByMsg = {};
  String? typingUserId;
  Timer? _typingTimer;
  bool loadingOlder = false;
  bool noMoreOlder = false;
  bool replyingMode = false;
  Message? replyTo;
  bool sendingMedia = false;
  double uploadProgress = 0;

  /// v0.1.0 pagination-window fix: after [loadOlder] the controller
  /// holds a window that reaches BACK in history. Refetching the
  /// latest page (the old behaviour on every realtime row / send /
  /// edit) silently dropped that history and snapped a reading user
  /// to the newest 30 messages. While [atLatest] is false we merge
  /// incoming changes into the loaded window instead, and count
  /// [newBelow] unseen arrivals so the UI can offer a jump chip.
  bool atLatest = true;
  int newBelow = 0;

  /// Real presence for 1:1 chats. The server answers with fresh
  /// heartbeats only (and honours the peer's privacy setting) — so
  /// `false` here means "not online / unknown", and the UI must never
  /// claim more than that.
  bool peerOnline = false;

  /// v0.1.0: peer's last-seen timestamp (server honours the peer's
  /// privacy settings and a shared-chat rule; absent = unknown and
  /// the UI must not invent anything).
  DateTime? peerLastSeen;
  Timer? _presenceTimer;

  /// v0.1.0: the chat's pinned message (sender-pinned server-side).
  /// Rendered as a tappable banner under the AppBar.
  Message? pinnedMessage;

  /// v0.1.0: the chat's disappearing-messages TTL in seconds (null =
  /// OFF). Mirrors `chat.disappearTtlSeconds` and is updated optimistically
  /// by [setDisappearTtl] before the server confirms.
  int? disappearTtl;

  /// v0.1.0: periodic sweep that drops expired (disappearing) messages
  /// from the open list + trims the local cache.
  Timer? _expiryTimer;

  StreamSubscription? _msgSub;
  StreamSubscription? _receiptSub;
  StreamSubscription? _reactionSub;
  StreamSubscription? _typingSub;

  String get myId => services.auth.userId!;
  bool get isGroup => chat.isGroup;
  String? get _peerId => chat.peer?.id;

  Future<void> start() async {
    disappearTtl = chat.disappearTtlSeconds;
    messages = await services.cache.page(chat.id);
    await _dropExpiredLocal();
    await _loadSocial();
    unawaited(loadPinned());
    notifyListeners();

    await services.messages.markDelivered(chat.id);
    await services.messages.markRead(chat.id);

    _startPresenceLoop();

    // v0.1.0: server-side GC for expired disappearing messages —
    // opportunistic (no pg_cron): every open sweeps this chat. Also a
    // local sweep timer while the screen is open.
    unawaited(_purgeExpiredServer());
    _expiryTimer = Timer.periodic(
        const Duration(seconds: 30), (_) => unawaited(_dropExpiredLocal()));

    _msgSub = services.realtime.messageEvents.listen(_onRow);
    _receiptSub = services.realtime.receiptEvents.listen((_) async {
      await _loadSocial();
      notifyListeners();
    });
    _reactionSub = services.realtime.reactionEvents.listen((_) async {
      await _loadSocial();
      notifyListeners();
    });
    _typingSub = services.realtime.typingEvents.listen((t) {
      if (t.chatId != chat.id || t.userId == myId) return;
      typingUserId = t.typing ? t.userId : null;
      notifyListeners();
      if (t.typing) {
        _typingTimer?.cancel();
        _typingTimer = Timer(
            const Duration(milliseconds: AppConfig.typingIndicatorTimeoutMs),
            () {
          typingUserId = null;
          notifyListeners();
        });
      }
    });

    unawaited(services.sync.syncChat(chat.id).then((_) async {
      await _refreshWindow();
      notifyListeners();
    }));
  }

  /// Re-read the latest page and merge it with whatever history the
  /// user has already loaded (see [atLatest]).
  Future<void> _refreshWindow() async {
    final latest = await services.cache.page(chat.id);
    messages = mergeWindow(messages, latest);
  }

  /// Pure, testable window merge: the latest page stays in front,
  /// already-loaded older messages are preserved behind it, newest
  /// first ordering (created_at DESC) is kept, ids dedupe.
  static List<Message> mergeWindow(
      List<Message> loaded, List<Message> latestPage) {
    if (latestPage.isEmpty) return loaded;
    final latestIds = latestPage.map((m) => m.id).toSet();
    final older = loaded.where((m) => !latestIds.contains(m.id)).toList();
    if (older.isEmpty) return latestPage;
    return [...latestPage, ...older];
  }

  /// Jump back to the newest window (chip / auto after send).
  Future<void> jumpToLatest() async {
    atLatest = true;
    newBelow = 0;
    messages = await services.cache.page(chat.id);
    await _loadSocial();
    notifyListeners();
  }

  Future<void> _loadSocial() async {
    final ids = messages.map((m) => m.id).toList();
    final rs = await services.cache.reactions(ids);
    reactionsByMsg = {};
    for (final r in rs) {
      (reactionsByMsg[r.messageId] ??= []).add(r);
    }
    // v0.1.9: الإيصالات تُحمّل لكل المحادثات (ثنائية ومجموعات) —
    // بلاطة «معلومات» في القائمة الطويلة صارت متاحة في الاثنين.
    // في الثنائية قد تكون ذاكرة الإيصالات فارغة (لا صفوف بعد) — آمن.
    receiptsByMsg = {};
    final rc = await services.cache.receipts(ids);
    for (final r in rc) {
      (receiptsByMsg[r.messageId] ??= []).add(r);
    }
  }

  Future<void> _onRow(Map<String, dynamic> row) async {
    if (row['chat_id'] != chat.id) return;
    // UPDATE events (edit/delete) — merge decrypted row.
    await services.sync.onRealtimeRow(row);
    final wasAtLatest = atLatest;
    await _refreshWindow();
    if (!wasAtLatest && row['sender_id'] != myId) {
      final id = row['id'] as String?;
      final stillLoaded = messages.any((m) => m.id == id);
      if (!stillLoaded) newBelow += 1;
    }
    await _loadSocial();
    notifyListeners();
    // mark incoming delivered/read immediately
    if (row['sender_id'] != myId) {
      await services.messages.markDelivered(chat.id);
      await services.messages.markRead(chat.id);
    }
  }

  // ------------------------------------------------------------------
  // Presence (1:1 only — groups show member count instead)
  // ------------------------------------------------------------------
  void _startPresenceLoop() {
    final peer = _peerId;
    if (isGroup || peer == null) return;
    // Our own heartbeat fires right away too (opening a chat means
    // the user is active right now).
    unawaited(services.presence.beat());
    unawaited(_refreshPresence());
    _presenceTimer = Timer.periodic(
      const Duration(seconds: AppConfig.presenceRefreshSecs),
      (_) => unawaited(_refreshPresence()),
    );
  }

  Future<void> _refreshPresence() async {
    final peer = _peerId;
    if (peer == null) return;
    final online =
        (await services.presence.onlineUsers([peer])).contains(peer);
    // v0.1.0: also poll last-seen (30-day window). Only used when the
    // peer is NOT online; the server enforces the same privacy rules.
    final lastSeen = await services.presence.lastSeenUsers([peer]);
    peerLastSeen = lastSeen[peer];
    if (online != peerOnline) {
      peerOnline = online;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Disappearing messages (v0.1.0)
  // ------------------------------------------------------------------
  /// Flip the chat's disappearing TTL (null = OFF). Optimistic: the
  /// banner updates immediately; the server RPC stamps future messages
  /// via trigger. NOTE: existing messages keep the expiry they were
  /// stamped with at send time (WhatsApp-like semantics).
  Future<void> setDisappearTtl(int? seconds) async {
    final old = disappearTtl;
    disappearTtl = (seconds == null || seconds <= 0) ? null : seconds;
    notifyListeners();
    try {
      await services.messages.setDisappearTtl(chat.id, seconds);
    } catch (_) {
      disappearTtl = old; // revert on failure
      notifyListeners();
    }
  }

  Future<void> _purgeExpiredServer() async {
    try {
      await services.messages.purgeExpired(chat.id);
    } catch (_) {
      // Offline / RPC unavailable — the local sweep still hides rows.
    }
  }

  /// Remove expired rows from the in-memory list + local cache.
  Future<void> _dropExpiredLocal() async {
    final now = DateTime.now().toUtc();
    final before = messages.length;
    final kept =
        messages.where((m) => !DisappearingPolicy.isExpired(m.expiresAt, now)).toList();
    if (kept.length != before) {
      messages = kept;
    }
    try {
      await services.cache.purgeExpired(chatId: chat.id);
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // Starred messages (v0.1.0)
  // ------------------------------------------------------------------
  /// Star / unstar a message. Optimistic locally (messages_cache.starred
  /// drives the «الرسائل المحفوظة» screen); the server row makes it
  /// survive re-installs through [starredIds] resync on next open.
  Future<void> toggleStar(Message m) async {
    final newStarred = !m.starred;
    await services.cache.setStarred(m.id, newStarred);
    messages = messages
        .map((x) => x.id == m.id || x.clientMsgId == m.id
            ? x.copyWith(starred: newStarred)
            : x)
        .toList();
    notifyListeners();
    try {
      await services.messages.toggleStar(m.id, newStarred);
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // Pinned message (v0.1.0)
  // ------------------------------------------------------------------
  /// Fetch the chat's pinned message through the normal server-row
  /// merge path (decrypt → cache → read back).
  Future<void> loadPinned() async {
    try {
      final row = await services.messages.fetchPinned(chat.id);
      if (row == null) {
        pinnedMessage = null;
      } else {
        await services.sync.mergeServerRows(chat, [row]);
        pinnedMessage = await services.cache.byId(row['id'] as String);
      }
      notifyListeners();
    } catch (_) {
      // Banner is cosmetic — offline it just stays hidden.
    }
  }

  /// Pin a message (sender-only server-side). Replaces the previous
  /// pin — the server surfaces at most one (most recent).
  Future<void> pinMessage(Message m) async {
    try {
      await services.messages.setPinned(m.id, true);
      await loadPinned();
    } catch (_) {}
  }

  Future<void> unpinPinned() async {
    final m = pinnedMessage;
    if (m == null) return;
    try {
      await services.messages.setPinned(m.id, false);
      pinnedMessage = null;
      notifyListeners();
    } catch (_) {}
  }

  // ------------------------------------------------------------------
  // Sending
  // ------------------------------------------------------------------
  Future<void> sendText(String text, {String? forwardedFrom}) async {
    if (text.trim().isEmpty) return;
    final m = await services.sync.enqueueText(chat, text.trim(),
        replyTo: replyTo?.id,
        replyPreview: replyTo?.text ?? '📎 وسائط',
        forwardedFrom: forwardedFrom);
    messages = [...messages, m];
    _clearReply();
    notifyListeners();
    await services.realtime.sendTyping(chat.id, false);
    await services.sync.drain();
    // Sending means the user is at the bottom — take the newest
    // window again (snapping here is the expected behaviour).
    atLatest = true;
    newBelow = 0;
    await _refreshWindow();
    notifyListeners();
  }

  Future<void> sendMedia(MediaUploadResult media,
      {String? caption, String? forwardedFrom}) async {
    final m = await services.sync.enqueueMedia(chat, media.toMediaInfo(),
        caption: caption,
        replyTo: replyTo?.id,
        replyPreview: '📎 ${media.type}',
        forwardedFrom: forwardedFrom);
    messages = [...messages, m];
    _clearReply();
    notifyListeners();
    await services.sync.drain();
    atLatest = true;
    newBelow = 0;
    await _refreshWindow();
    notifyListeners();
  }

  /// v0.1.10 — publish an encrypted poll into this chat.
  Future<void> sendPoll(String question, List<String> options) async {
    if (question.trim().isEmpty || options.length < 2) return;
    final m = await services.sync.enqueuePoll(
        chat, question.trim(), options.map((o) => o.trim()).toList());
    messages = [...messages, m];
    _clearReply();
    notifyListeners();
    await services.sync.drain();
    atLatest = true;
    newBelow = 0;
    await _refreshWindow();
    notifyListeners();
  }

  /// v0.1.10 — cast (or change) my ballot on [pollMsg]. Optimistic:
  /// the placeholder ballot updates the tally instantly; the encrypted
  /// row follows through the normal outbox path. Votes are hidden from
  /// the transcript — the bubble re-renders from the tally.
  Future<void> castVote(Message pollMsg, int optionIndex) async {
    if (pollMsg.poll == null) return;
    try {
      await services.sync.enqueuePollVote(chat, pollMsg, optionIndex);
      notifyListeners();
    } catch (_) {
      // Invalid option / no poll — silently ignore (bubble stays put).
    }
  }

  Future<void> editMessage(Message m, String newText) async {
    await services.cache.applyEdit(m.id, newText);
    messages = messages
        .map((x) => x.id == m.id
            ? x.copyWith(
                text: newText,
                editedAt:
                    m.editedAt ?? DateTime.now().toUtc().toIso8601String())
            : x)
        .toList();
    notifyListeners();
    await services.sync.enqueueEdit(m.id, chat, {
      'kind': 'text',
      'text': newText,
      if (m.media != null) 'media': m.media!.toJson(),
    });
  }

  Future<void> deleteForEveryone(Message m) async {
    await services.sync.enqueueDelete(m.id, chat);
    messages = messages
        .map((x) =>
            x.id == m.id ? x.copyWith(isDeletedForAll: true, text: null) : x)
        .toList();
    notifyListeners();
  }

  Future<void> deleteForMe(Message m) async {
    await services.cache.deleteForMe(m.id);
    try {
      await services.messages.deleteForMe(m.id);
    } catch (_) {}
    messages = messages.where((x) => x.id != m.id).toList();
    notifyListeners();
  }

  Future<void> toggleReaction(Message m, String emoji) async {
    final existing =
        reactionsByMsg[m.id]?.where((r) => r.userId == myId).toList() ?? [];
    final newEmoji =
        (existing.isNotEmpty && existing.first.emoji == emoji) ? '' : emoji;
    await services.cache.upsertReaction(Reaction(
        m.id, myId, newEmoji, DateTime.now().toUtc().toIso8601String()));
    try {
      await services.messages.react(m.id, newEmoji);
    } catch (_) {}
    await _loadSocial();
    notifyListeners();
  }

  Future<void> togglePin(Message m) => pinMessage(m);

  // ------------------------------------------------------------------
  // Pagination
  // ------------------------------------------------------------------
  Future<void> loadOlder() async {
    if (loadingOlder || noMoreOlder || messages.isEmpty) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final before = messages.first.createdAt;
      // server page first (fills cache), then read the merged page
      final rows = await services.messages
          .fetchMessages(chatId: chat.id, beforeIso: before);
      if (rows.isNotEmpty) {
        await services.sync.mergeServerRows(chat, rows);
      }
      final page = await services.cache.page(chat.id, beforeIso: before);
      if (page.length < 10) noMoreOlder = true;
      if (page.isNotEmpty) {
        messages = [...page, ...messages];
        // The window now extends into history — incoming realtime
        // rows must merge, never replace (see [atLatest]).
        atLatest = false;
      }
    } catch (_) {
      noMoreOlder = true;
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  // ------------------------------------------------------------------
  // Typing
  // ------------------------------------------------------------------
  void onTyping() {
    services.realtime.sendTyping(chat.id, true);
  }

  // ------------------------------------------------------------------
  // Reply / selection helpers
  // ------------------------------------------------------------------
  void startReply(Message m) {
    replyingMode = true;
    replyTo = m;
    notifyListeners();
  }

  void _clearReply() {
    replyingMode = false;
    replyTo = null;
  }

  void cancelReply() {
    _clearReply();
    notifyListeners();
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _receiptSub?.cancel();
    _reactionSub?.cancel();
    _typingSub?.cancel();
    _typingTimer?.cancel();
    _presenceTimer?.cancel();
    _expiryTimer?.cancel();
    super.dispose();
  }
}

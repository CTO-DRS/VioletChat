/// ============================================================
/// Domain models — hand-written JSON mapping (no codegen).
/// ============================================================
library;

class Profile {
  final String id;
  final String username;
  final String displayName;
  final String? avatarPath;
  final String? bio;
  final String createdAt;

  /// v0.1.1 — global platform role ('user' | 'admin'). Server-side only:
  /// column-level grants revoke UPDATE/INSERT for authenticated users, so
  /// nobody can self-promote; changes go through admin_set_role RPC.
  final String role;

  /// v0.1.1 — platform verification badge (profiles.is_verified).
  /// Granted/revoked by admins via admin_set_verified; rendered as the
  /// blue check next to the name everywhere profiles appear.
  final bool isVerified;

  const Profile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarPath,
    this.bio,
    required this.createdAt,
    this.role = 'user',
    this.isVerified = false,
  });

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        username: (j['username'] ?? '') as String,
        displayName: (j['display_name'] ?? '') as String,
        avatarPath: j['avatar_path'] as String?,
        bio: j['bio'] as String?,
        createdAt: (j['created_at'] ?? '') as String,
        role: (j['role'] ?? 'user') as String,
        isVerified: (j['is_verified'] ?? false) as bool,
      );

  /// Platform-level admin (NOT the group-level ChatMember.isAdmin).
  bool get isPlatformAdmin => role == 'admin';

  String get title =>
      displayName.trim().isNotEmpty ? displayName.trim() : username;

  String get initial =>
      title.trim().isEmpty ? '؟' : title.trim().substring(0, 1);

  int get colorSeed {
    var h = 0;
    for (var i = 0; i < id.length; i++) {
      h = (h * 31 + id.codeUnitAt(i)) & 0x7fffffff;
    }
    return h;
  }
}

class Device {
  final String deviceId;
  final String userId;
  final String deviceName;
  final String platform;
  final String createdAt;
  final String? lastActiveAt;

  const Device({
    required this.deviceId,
    required this.userId,
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    this.lastActiveAt,
  });

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        deviceId: j['device_id'] as String,
        userId: j['user_id'] as String,
        deviceName: (j['device_name'] ?? '') as String,
        platform: (j['platform'] ?? '') as String,
        createdAt: (j['created_at'] ?? '') as String,
        lastActiveAt: j['last_active_at'] as String?,
      );
}

class ChatMember {
  final Profile profile;
  final String role;
  final String joinedAt;

  const ChatMember({
    required this.profile,
    required this.role,
    required this.joinedAt,
  });

  factory ChatMember.fromJson(Map<String, dynamic> j) => ChatMember(
        profile: Profile.fromJson(j['profile'] as Map<String, dynamic>),
        role: (j['role'] ?? AppRoles.member) as String,
        joinedAt: (j['joined_at'] ?? '') as String,
      );

  bool get isOwner => role == AppRoles.owner;
  bool get isAdmin => role == AppRoles.owner || role == AppRoles.admin;
}

class AppRoles {
  static const String owner = 'owner';
  static const String admin = 'admin';
  static const String member = 'member';
}

class Chat {
  final String id;
  final String type; // direct | group
  final Profile? peer; // direct: the other user
  final String name; // group
  final String? description;
  final String? avatarPath;
  final String? createdBy;
  final String? inviteCode;
  final String? myRole;
  final String createdAt;
  final String? lastMessageAt;

  // v0.1.0 per-member chat state (my own view, server-side in
  // chat_members via set_chat_flags RPC). null = untouched.
  final String? pinnedAt;
  final String? mutedUntil;
  final String? archivedAt;

  /// v0.1.0: disappearing-messages TTL for the chat, in seconds
  /// (server: chats.disappear_ttl_seconds via get_my_chats).
  /// null = OFF. Timing metadata only — content stays E2E.
  final int? disappearTtlSeconds;

  const Chat({
    required this.id,
    required this.type,
    this.peer,
    this.name = '',
    this.description,
    this.avatarPath,
    this.createdBy,
    this.inviteCode,
    this.myRole,
    required this.createdAt,
    this.lastMessageAt,
    this.pinnedAt,
    this.mutedUntil,
    this.archivedAt,
    this.disappearTtlSeconds,
  });

  bool get isGroup => type == 'group';

  bool get isPinned => pinnedAt != null;

  bool get isArchived => archivedAt != null;

  /// Muted = muted_until set AND still in the future. The server never
  /// returns a past timestamp through set_chat_flags (clear sets null),
  /// but the double-check makes clock skew harmless.
  bool get isMuted {
    final until = mutedUntil;
    if (until == null) return false;
    final t = DateTime.tryParse(until);
    return t != null && t.isAfter(DateTime.now());
  }

  factory Chat.fromJson(Map<String, dynamic> j, String myId) {
    final type = (j['type'] ?? 'direct') as String;
    return Chat(
      id: j['id'] as String,
      type: type,
      peer: j['peer'] == null
          ? null
          : Profile.fromJson(j['peer'] as Map<String, dynamic>),
      name: (j['name'] ?? '') as String,
      description: j['description'] as String?,
      avatarPath: j['avatar_path'] as String?,
      createdBy: j['created_by'] as String?,
      inviteCode: j['invite_code'] as String?,
      myRole: j['my_role'] as String?,
      createdAt: (j['created_at'] ?? '') as String,
      lastMessageAt: j['last_message_at'] as String?,
      pinnedAt: (j['my_pinned_at'] ?? j['pinned_at']) as String?,
      mutedUntil: (j['my_muted_until'] ?? j['muted_until']) as String?,
      archivedAt: (j['my_archived_at'] ?? j['archived_at']) as String?,
      disappearTtlSeconds: (j['disappear_ttl_seconds'] as num?)?.toInt(),
    );
  }

  String get title => isGroup ? name : (peer?.title ?? '');

  /// v0.1.0: flags-only copy for optimistic local updates (pin / mute
  /// / archive). Sentinel-aware: passing an explicit null CLEARS the
  /// flag, omitting the argument (or passing [flagUnset]) leaves it
  /// untouched.
  static const Object flagUnset = Object();
  static const Object _unset = flagUnset;

  Chat copyWithFlags({
    Object? pinnedAt = _unset,
    Object? mutedUntil = _unset,
    Object? archivedAt = _unset,
    Object? disappearTtlSeconds = _unset,
  }) =>
      Chat(
        id: id,
        type: type,
        peer: peer,
        name: name,
        description: description,
        avatarPath: avatarPath,
        createdBy: createdBy,
        inviteCode: inviteCode,
        myRole: myRole,
        createdAt: createdAt,
        lastMessageAt: lastMessageAt,
        pinnedAt: pinnedAt == _unset ? this.pinnedAt : pinnedAt as String?,
        mutedUntil:
            mutedUntil == _unset ? this.mutedUntil : mutedUntil as String?,
        archivedAt:
            archivedAt == _unset ? this.archivedAt : archivedAt as String?,
        disappearTtlSeconds: disappearTtlSeconds == _unset
            ? this.disappearTtlSeconds
            : disappearTtlSeconds as int?,
      );
}

class MediaInfo {
  final String type; // image | audio | video | file
  final String path; // storage path (server-side, needed for RLS)
  final int size;
  final String mime;
  final String? name;
  final int? width;
  final int? height;
  final int? durationMs;
  final String fileKey; // b64 AES key of the encrypted blob
  final String fileNonce; // b64 nonce
  final String? thumbPath;
  final String? thumbKey;
  final String? thumbNonce;

  const MediaInfo({
    required this.type,
    required this.path,
    required this.size,
    required this.mime,
    this.name,
    this.width,
    this.height,
    this.durationMs,
    required this.fileKey,
    required this.fileNonce,
    this.thumbPath,
    this.thumbKey,
    this.thumbNonce,
  });

  Map<String, dynamic> toJson() => {
        'type': type,
        'path': path,
        'size': size,
        'mime': mime,
        if (name != null) 'name': name,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (durationMs != null) 'dur': durationMs,
        'fkey': fileKey,
        'fnonce': fileNonce,
        if (thumbPath != null) 'thumb': thumbPath,
        if (thumbKey != null) 'tkey': thumbKey,
        if (thumbNonce != null) 'tnonce': thumbNonce,
      };

  static MediaInfo? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return MediaInfo(
      type: (j['type'] ?? 'file') as String,
      path: (j['path'] ?? '') as String,
      size: (j['size'] ?? 0) as int,
      mime: (j['mime'] ?? 'application/octet-stream') as String,
      name: j['name'] as String?,
      width: j['w'] as int?,
      height: j['h'] as int?,
      durationMs: j['dur'] as int?,
      fileKey: (j['fkey'] ?? '') as String,
      fileNonce: (j['fnonce'] ?? '') as String,
      thumbPath: j['thumb'] as String?,
      thumbKey: j['tkey'] as String?,
      thumbNonce: j['tnonce'] as String?,
    );
  }
}

/// v0.1.10 — encrypted poll payload. The question and the options live
/// INSIDE the ciphertext (E2E); the server only ever sees kind='poll'.
/// Votes are separate 'pollVote' message rows whose plaintext reply_to
/// links them to the poll row; the ballot itself (option index) is
/// encrypted like any other message. Tallying is client-side (see
/// PollTally) — the server cannot count what it cannot read.
class PollInfo {
  /// Stable identity inside the ciphertext. On the server the poll's
  /// message row id is the natural link, but the id is not known before
  /// INSERT — so the creator mints a client-side id and carries it in
  /// every ballot too (defence in depth against reply_to spoofing).
  final String pollId;
  final String question;
  final List<String> options;

  /// v1: single-choice polls only. Kept in the wire format so future
  /// multi-choice versions can coexist without a schema bump.
  final bool multi;

  const PollInfo({
    required this.pollId,
    required this.question,
    required this.options,
    this.multi = false,
  });

  Map<String, dynamic> toJson() => {
        'pollId': pollId,
        'question': question,
        'options': options,
        'multi': multi,
      };

  static PollInfo? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    try {
      final opts = (j['options'] as List?)
              ?.map((e) => '$e')
              .toList() ??
          const <String>[];
      return PollInfo(
        pollId: (j['pollId'] ?? '') as String,
        question: (j['question'] ?? '') as String,
        options: opts,
        multi: (j['multi'] ?? false) as bool,
      );
    } catch (_) {
      return null;
    }
  }

  /// Defensive index check for incoming ballots.
  bool isValidOption(int i) => i >= 0 && i < options.length;
}

/// Lifecycle of an outgoing message on THIS device.
enum MsgState { queued, sending, sent, delivered, read, failed }

class Message {
  final String id;
  final String chatId;
  final String senderId;
  final String senderDeviceId;
  final String clientMsgId;
  final String kind; // text | media | system | poll | pollVote
  final String? text; // decrypted
  final MediaInfo? media; // decrypted

  /// v0.1.10: decrypted poll body (kind == 'poll' only).
  final PollInfo? poll;

  /// v0.1.10: decrypted ballot option index (kind == 'pollVote' only).
  final int? pollVote;

  /// v0.1.10: encrypted poll linkage for ballots — the creator's
  /// client-side PollInfo.pollId. ALWAYS present on ballots (travels
  /// inside the ciphertext); reply_to duplicates it in plaintext only
  /// when the poll row id is already known (FK-safe).
  final String? pollRef;
  final String? replyTo;
  final String? replyPreview;

  /// v0.1.0: set when the row arrived via "إعادة توجيه" — carries the
  /// ORIGINAL message id (plaintext column + inner payload), rendered
  /// as a «مُعاد توجيهه» chip on the bubble.
  final String? forwardedFrom;
  final bool isDeletedForAll;
  final String? editedAt;

  /// v0.1.0: server-stamped expiry (messages.expires_at — trigger from
  /// chats.disappear_ttl_seconds at INSERT). null = never expires.
  final String? expiresAt;

  /// v0.1.0: starred by ME on THIS device (messages_cache.starred).
  final bool starred;
  final String createdAt;
  final String serverAt;
  final int keyVersion;
  final MsgState localState; // only meaningful for outgoing
  final String? failureReason;
  final bool decrypted;

  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderDeviceId,
    required this.clientMsgId,
    required this.kind,
    this.text,
    this.media,
    this.poll,
    this.pollVote,
    this.pollRef,
    this.replyTo,
    this.replyPreview,
    this.forwardedFrom,
    this.isDeletedForAll = false,
    this.editedAt,
    this.expiresAt,
    this.starred = false,
    required this.createdAt,
    required this.serverAt,
    this.keyVersion = 0,
    this.localState = MsgState.sent,
    this.failureReason,
    this.decrypted = true,
  });

  static Message placeholder({
    required String clientMsgId,
    required String chatId,
    required String senderId,
    required String senderDeviceId,
    required String? text,
    required MediaInfo? media,
    required String kind,
    String? replyTo,
    String? replyPreview,
    PollInfo? poll,
    int? pollVote,
    String? pollRef,
  }) =>
      Message(
        id: clientMsgId, // provisional id until server confirms
        chatId: chatId,
        senderId: senderId,
        senderDeviceId: senderDeviceId,
        clientMsgId: clientMsgId,
        kind: kind,
        text: text,
        media: media,
        poll: poll,
        pollVote: pollVote,
        pollRef: pollRef,
        replyTo: replyTo,
        replyPreview: replyPreview,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        serverAt: '',
        localState: MsgState.sending,
      );

  bool get isMinePlaceholder => id == clientMsgId;

  /// Targeted copies for in-place history updates (edit / delete /
  /// local state transitions) without touching the cache layer.
  Message copyWith({
    String? text,
    bool? isDeletedForAll,
    String? editedAt,
    bool? starred,
    MsgState? localState,
    String? failureReason,
    String? forwardedFrom,
    PollInfo? poll,
    int? pollVote,
    String? pollRef,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        senderDeviceId: senderDeviceId,
        clientMsgId: clientMsgId,
        kind: kind,
        text: text ?? this.text,
        media: media,
        poll: poll ?? this.poll,
        pollVote: pollVote ?? this.pollVote,
        pollRef: pollRef ?? this.pollRef,
        replyTo: replyTo,
        replyPreview: replyPreview,
        forwardedFrom: forwardedFrom ?? this.forwardedFrom,
        isDeletedForAll: isDeletedForAll ?? this.isDeletedForAll,
        editedAt: editedAt ?? this.editedAt,
        expiresAt: expiresAt,
        starred: starred ?? this.starred,
        createdAt: createdAt,
        serverAt: serverAt,
        keyVersion: keyVersion,
        localState: localState ?? this.localState,
        failureReason: failureReason ?? this.failureReason,
        decrypted: decrypted,
      );
}

class Receipt {
  final String messageId;
  final String userId;
  final String? deliveredAt;
  final String? readAt;

  const Receipt(this.messageId, this.userId, this.deliveredAt, this.readAt);

  factory Receipt.fromJson(Map<String, dynamic> j) => Receipt(
        j['message_id'] as String,
        j['user_id'] as String,
        j['delivered_at'] as String?,
        j['read_at'] as String?,
      );
}

class Reaction {
  final String messageId;
  final String userId;
  final String emoji;
  final String createdAt;

  const Reaction(this.messageId, this.userId, this.emoji, this.createdAt);

  factory Reaction.fromJson(Map<String, dynamic> j) => Reaction(
        j['message_id'] as String,
        j['user_id'] as String,
        (j['emoji'] ?? '') as String,
        (j['created_at'] ?? '') as String,
      );
}

class OutboxItem {
  final String id; // clientMsgId
  final String chatId;
  final String action; // send | edit | delete
  final String payload; // JSON
  final int attempts;
  final String createdAt;
  final String nextAttemptAt;
  final String? lastError;

  const OutboxItem({
    required this.id,
    required this.chatId,
    required this.action,
    required this.payload,
    required this.attempts,
    required this.createdAt,
    required this.nextAttemptAt,
    this.lastError,
  });
}

class CallRecord {
  final String id;
  final String chatId;
  final String callerId;
  final String calleeId;
  final String type; // audio | video
  final String status; // ringing/active/ended/missed/declined
  final String createdAt;
  final int durationSec;

  const CallRecord({
    required this.id,
    required this.chatId,
    required this.callerId,
    required this.calleeId,
    required this.type,
    required this.status,
    required this.createdAt,
    required this.durationSec,
  });

  factory CallRecord.fromJson(Map<String, dynamic> j) => CallRecord(
        id: j['id'] as String,
        chatId: j['chat_id'] as String,
        callerId: j['caller_id'] as String,
        calleeId: j['callee_id'] as String,
        type: (j['type'] ?? 'audio') as String,
        status: (j['status'] ?? 'ended') as String,
        createdAt: (j['created_at'] ?? '') as String,
        durationSec: (j['duration_sec'] ?? 0) as int,
      );
}

class JoinRequest {
  final String id;
  final String chatId;
  final Profile profile;
  final String status;
  final String createdAt;

  const JoinRequest(
      this.id, this.chatId, this.profile, this.status, this.createdAt);

  factory JoinRequest.fromJson(Map<String, dynamic> j) => JoinRequest(
        j['id'] as String,
        j['chat_id'] as String,
        Profile.fromJson(j['profile'] as Map<String, dynamic>),
        (j['status'] ?? 'pending') as String,
        (j['created_at'] ?? '') as String,
      );
}

class UserSettings {
  final bool darkMode;
  final bool notificationPreview;
  final bool notificationSound;
  final bool notificationVibration;
  final bool readReceipts;

  /// When false, the server removes/stops recording our presence row —
  /// other users can never see us "متصل الآن". Enforced server-side
  /// inside presence_heartbeat() / get_presence(); the flag here only
  /// drives the UI.
  final bool showPresence;

  /// Device privacy (v0.1.0): require biometric unlock when the app
  /// comes back from background. Synced via the settings JSONB (no
  /// schema change) — enforced only on devices that HAVE biometrics;
  /// elsewhere the lock gate silently skips (fail-safe, never lockout).
  final bool appLock;

  /// Device privacy (v0.1.0): FLAG_SECURE — app appears in the
  /// recents switcher without content and screenshots/screen-record
  /// are blocked by the OS while the app is visible.
  final bool blockScreenshots;

  /// Device privacy (v0.1.0): how long the app may sit in the
  /// background before the biometric lock engages again.
  /// 0 = lock immediately (v0.1.0 behaviour), 60 = after a minute,
  /// 300 = after five minutes. Cold starts always lock immediately —
  /// the grace window only covers quick app switches.
  final int appLockGraceSecs;

  /// v0.1.0: 'dark' | 'light' | 'system'. Falls back to the legacy
  /// dark_mode boolean when absent (older clients / older rows), so
  /// nothing breaks either direction.
  final String themeMode;

  /// v0.1.9: حجم خط نص الرسائل داخل شاشة المحادثة (13–22).
  /// يُحفظ في settings JSONB (بلا تغيير مخطط) — أي قيمة خارج النطاق
  /// تُرجَع إلى الافتراضي 15 عند القراءة (defensive decode).
  final int chatFontSize;

  const UserSettings({
    this.darkMode = true,
    this.notificationPreview = false,
    this.notificationSound = true,
    this.notificationVibration = true,
    this.readReceipts = true,
    this.showPresence = true,
    this.appLock = false,
    this.blockScreenshots = false,
    this.appLockGraceSecs = 0,
    this.themeMode = '',
    this.chatFontSize = UserSettings.defaultChatFontSize,
  });

  /// الافتراضي المعلن — المستخدم نفسه في الاختبارات وواجهة الإعدادات.
  static const int defaultChatFontSize = 15;
  static const int minChatFontSize = 13;
  static const int maxChatFontSize = 22;

  factory UserSettings.fromJson(Map<String, dynamic> j) => UserSettings(
        darkMode: (j['dark_mode'] ?? true) as bool,
        notificationPreview: (j['notification_preview'] ?? false) as bool,
        notificationSound: (j['notification_sound'] ?? true) as bool,
        notificationVibration: (j['notification_vibration'] ?? true) as bool,
        readReceipts: (j['read_receipts'] ?? true) as bool,
        showPresence: (j['show_presence'] ?? true) as bool,
        appLock: (j['app_lock'] ?? false) as bool,
        blockScreenshots: (j['block_screenshots'] ?? false) as bool,
        appLockGraceSecs: _graceFromJson(j['app_lock_grace_secs']),
        themeMode: (j['theme_mode'] ?? '') as String,
        chatFontSize: _fontFromJson(j['chat_font_size']),
      );

  /// Resolved theme preference: explicit theme_mode wins; legacy
  /// dark_mode boolean is the fallback for rows that never saw v0.1.0.
  String get resolvedThemeMode {
    switch (themeMode) {
      case 'system':
      case 'light':
      case 'dark':
        return themeMode;
      default:
        return darkMode ? 'dark' : 'light';
    }
  }

  /// Defensive decode: anything that is not one of the three supported
  /// windows (0/60/300) falls back to 0 — the strictest safe value.
  static int _graceFromJson(dynamic v) {
    final n = (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;
    return const [0, 60, 300].contains(n) ? n : 0;
  }

  /// v0.1.9 defensive decode: قيم غائبة/غير رقمية أو خارج [13,22]
  /// ترجع إلى الافتراضي 15 — أجهزة قديمة وأسطر JSON قديمة تعمل بلا كسر.
  static int _fontFromJson(dynamic v) {
    final n = (v is num) ? v.toInt() : int.tryParse('$v');
    if (n == null) return defaultChatFontSize;
    if (n < minChatFontSize || n > maxChatFontSize) {
      return defaultChatFontSize;
    }
    return n;
  }

  /// نسخة معدّلة بحجم خط جديد — تُستخدم من شريط الإعدادات.
  UserSettings withChatFontSize(int size) => UserSettings(
        darkMode: darkMode,
        notificationPreview: notificationPreview,
        notificationSound: notificationSound,
        notificationVibration: notificationVibration,
        readReceipts: readReceipts,
        showPresence: showPresence,
        appLock: appLock,
        blockScreenshots: blockScreenshots,
        appLockGraceSecs: appLockGraceSecs,
        themeMode: themeMode,
        chatFontSize: size.clamp(minChatFontSize, maxChatFontSize),
      );

  Map<String, dynamic> toJson() => {
        'dark_mode': darkMode,
        'notification_preview': notificationPreview,
        'notification_sound': notificationSound,
        'notification_vibration': notificationVibration,
        'read_receipts': readReceipts,
        'show_presence': showPresence,
        'app_lock': appLock,
        'block_screenshots': blockScreenshots,
        'app_lock_grace_secs': appLockGraceSecs,
        'theme_mode': resolvedThemeMode,
        'chat_font_size': chatFontSize,
      };
}

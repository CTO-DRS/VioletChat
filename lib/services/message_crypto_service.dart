import 'dart:convert';

import '../crypto/envelope.dart';
import '../crypto/group_keys.dart';
import '../crypto/identity.dart';
import '../crypto/primitives.dart';
import '../core/storage/local_database.dart';
import '../data/models/models.dart';
import '../data/repositories/chat_repository.dart';
import '../data/repositories/key_repository.dart';
import 'session_manager.dart';

/// High-level message crypto:
///  - direct chats  -> Double Ratchet per peer device
///  - group chats   -> versioned group key (+ rotation on membership)
///  - system msgs   -> plaintext envelope (no content to protect)
class MessageCryptoService {
  final SessionManager sessions;
  final ChatRepository chats;
  final KeyRepository keys;
  final DeviceIdentity identity;

  MessageCryptoService(this.sessions, this.chats, this.keys, this.identity);

  // ==================================================================
  // GROUP KEYS
  // ==================================================================

  Future<int> currentGroupVersion(String chatId) async {
    final cached = await _kvGet('gk:$chatId:current');
    if (cached != null) return int.parse(cached);
    final v = await chats.latestKeyVersion(chatId);
    await _kvSet('gk:$chatId:current', '$v');
    return v;
  }

  /// Get (and cache) the group key for [version].
  Future<GroupKeyEnvelope> groupKey(String chatId, int version) async {
    final cacheKey = 'gk:$chatId:v$version';
    final cachedRaw = await _kvGet(cacheKey);
    if (cachedRaw != null) {
      final json = await LocalDatabase.openJson(cachedRaw);
      if (json != null) {
        return GroupKeyEnvelope(version, Primitives.unb64(json['k'] as String));
      }
    }

    final wrap = await chats.fetchMyWrap(chatId, version);
    if (wrap == null) {
      throw StateError('no wrap for group key v$version — '
          'you were probably removed from this group');
    }
    final authorPub = await chats.wrapAuthorIdentityKey(chatId, version);
    if (authorPub == null) {
      throw StateError('wrap author identity not found');
    }
    final key = await GroupKeys.unwrap(
      wrappedB64: wrap.wrapped,
      nonceB64: wrap.nonce,
      version: version,
      myIdentity: identity.ik,
      wrapperIdentityPubB64: authorPub,
      chatId: chatId,
    );
    await _kvSet(
        cacheKey,
        await LocalDatabase.sealJson({
          'k': Primitives.b64(key.key),
        }));
    return key;
  }

  /// Rotate the group key: create version N+1, wrap it ONLY for the
  /// devices of CURRENT members, publish wraps.
  /// Returns the new version (0 when caller is not an admin).
  Future<int> rotateGroupKey(String chatId) async {
    final members = await chats.loadMembers(chatId);
    final me = members.where((m) => m.profile.id == identityUserId);
    if (me.isEmpty || !me.first.isAdmin) return 0;

    final newVersion = await chats.startKeyVersion(chatId);
    final newKey = GroupKeys.generate(newVersion);

    final wraps = <Map<String, dynamic>>[];
    for (final m in members) {
      final bundles = await keys.fetchBundles(m.profile.id);
      for (final b in bundles) {
        final memberIk = b.identityKey;
        final (wrapped, nonce) = await GroupKeys.wrapFor(
          groupKey: newKey,
          wrapperIdentity: identity.ik,
          memberIdentityPubB64: memberIk,
          chatId: chatId,
        );
        wraps.add({
          'user_id': m.profile.id,
          'device_id': b.deviceId,
          'wrapped': wrapped,
          'nonce': nonce,
        });
      }
    }
    await chats.uploadGroupKeyWraps(chatId, newVersion, wraps);
    await _kvSet('gk:$chatId:current', '$newVersion');
    // Cache my own key immediately.
    await _kvSet(
        'gk:$chatId:v$newVersion',
        await LocalDatabase.sealJson({
          'k': Primitives.b64(newKey.key),
        }));
    return newVersion;
  }

  // ==================================================================
  // OUTGOING
  // ==================================================================

  /// Encrypt an inner payload (JSON map) for [chat].
  Future<Map<String, dynamic>> encryptInner(
      Chat chat, Map<String, dynamic> inner) async {
    if (chat.isGroup) {
      final version = await currentGroupVersion(chat.id);
      final key = await groupKey(chat.id, version);
      final aeadKey = await GroupKeys.messageKey(key, chat.id);
      final (nonce, ct) = await Primitives.sealRandom(
          Primitives.bytesOf(jsonEncode(inner)), aeadKey);
      return MessageEnvelope.group(
        senderDeviceId: identity.deviceId,
        keyVersion: version,
        nonce: nonce,
        ciphertext: ct,
      );
    }

    final peerId = chat.peer!.id;
    final entries = await sessions.encryptDirect(
        chat.id, peerId, Primitives.bytesOf(jsonEncode(inner)));
    return MessageEnvelope.direct(
        senderDeviceId: identity.deviceId, entries: entries);
  }

  Map<String, dynamic> systemEnvelope(String text) =>
      MessageEnvelope.system(senderDeviceId: identity.deviceId, text: text);

  // ==================================================================
  // INCOMING
  // ==================================================================

  /// Decrypt a server message row into an inner payload.
  Future<InnerPayload> decryptRow(
      Chat chat, String senderId, Map<String, dynamic> body) async {
    if (MessageEnvelope.isSystem(body)) {
      return InnerPayload(
        kind: 'system',
        text: MessageEnvelope.systemText(body),
      );
    }

    if (MessageEnvelope.isDirect(body)) {
      final entry = MessageEnvelope.entryFor(body, identity.deviceId);
      if (entry == null) {
        return const InnerPayload(
            kind: 'text',
            decrypted: false,
            text: '🔒 رسالة موجّهة لجهاز آخر — افتحها من الجهاز المسجّل');
      }
      try {
        final plain = await sessions.decryptDirect(
            chat.id, MessageEnvelope.senderDevice(body), entry);
        final json =
            jsonDecode(Primitives.utf8s(plain)) as Map<String, dynamic>;
        return InnerPayload.fromJson(json);
      } catch (_) {
        return const InnerPayload(
            kind: 'text',
            decrypted: false,
            text: '🔒 تعذر فك التشفير بهذا الجهاز');
      }
    }

    // Group
    final version = MessageEnvelope.groupKeyVersion(body);
    try {
      final key = await groupKey(chat.id, version);
      final aeadKey = await GroupKeys.messageKey(key, chat.id);
      final plain = await Primitives.open(
        Primitives.unb64(body['c'] as String),
        aeadKey,
        Primitives.unb64(body['n'] as String),
      );
      final json = jsonDecode(Primitives.utf8s(plain)) as Map<String, dynamic>;
      return InnerPayload.fromJson(json);
    } catch (_) {
      return const InnerPayload(
          kind: 'text',
          decrypted: false,
          text: '🔒 رسالة مشفرة بمفتاح قديم أو غير متوفر');
    }
  }
}

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

class InnerPayload {
  final String kind; // text | media | system
  final String? text;
  final MediaInfo? media;
  final String? replyTo;

  /// v0.1.0: original message id when this row arrived by forwarding.
  /// Rides INSIDE the ciphertext (E2E metadata) and is mirrored in the
  /// plaintext forwarded_from column, exactly like replyTo.
  final String? forwardedFrom;
  final bool decrypted;

  const InnerPayload({
    required this.kind,
    this.text,
    this.media,
    this.replyTo,
    this.forwardedFrom,
    this.decrypted = true,
  });

  factory InnerPayload.fromJson(Map<String, dynamic> j) => InnerPayload(
        kind: (j['kind'] ?? 'text') as String,
        text: j['text'] as String?,
        media: MediaInfo.fromJson(j['media'] as Map<String, dynamic>?),
        replyTo: j['replyTo'] as String?,
        forwardedFrom: j['forwardedFrom'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (text != null) 'text': text,
        if (media != null) 'media': media!.toJson(),
        if (replyTo != null) 'replyTo': replyTo,
        if (forwardedFrom != null) 'forwardedFrom': forwardedFrom,
      };
}

// tiny local kv wrappers over the local database
extension _KvX on MessageCryptoService {
  String get identityUserId => chats.client.auth.currentUser?.id ?? '';

  Future<String?> _kvGet(String k) => LocalDatabase.kvGet(k);
  Future<void> _kvSet(String k, String v) => LocalDatabase.kvSet(k, v);
}

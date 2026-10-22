import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'primitives.dart';

/// ============================================================
/// Group key management — versioned sender scheme.
///
/// Design (matches SECURITY threat model, see SECURITY.md):
///  - Version V of a group chat has ONE 32-byte group key.
///  - Messages always carry the version they were encrypted with.
///  - Whenever membership changes (add / remove / leave / role
///    change), an admin creates version V+1 and wraps the new key
///    ONLY for the devices of CURRENT members. Removed members
///    never receive it => they cannot read future messages.
///  - Wrapping uses pairwise X25519 (wrapper identity key ×
///    member identity key) + HKDF with the chat/version as salt,
///    i.e. a fresh KEK per (chat, version, member).
/// ============================================================
class GroupKeyEnvelope {
  final int version;
  final Uint8List key; // 32 bytes

  const GroupKeyEnvelope(this.version, this.key);

  Uint8List get messageAeadKey =>
      Uint8List.sublistView(key); // direct AES-256 key
}

class GroupKeys {
  GroupKeys._();

  static const String _wrapInfo = 'drs-nexora-group-wrap-v1';
  static const String _msgInfo = 'drs-nexora-group-msg-v1';

  /// Generate a fresh group key for a new version.
  static GroupKeyEnvelope generate(int version) =>
      GroupKeyEnvelope(version, Primitives.randomBytes(32));

  /// Wrap a group key for one member device.
  /// KEK = HKDF(DH(wrapperIdentity, memberIdentity),
  ///            salt = chatId|version, info = wrap)
  /// Returns (wrappedB64, nonceB64).
  static Future<(String, String)> wrapFor({
    required GroupKeyEnvelope groupKey,
    required SimpleKeyPair wrapperIdentity,
    required String memberIdentityPubB64,
    required String chatId,
  }) async {
    final dhOut = await Primitives.dh(wrapperIdentity, memberIdentityPubB64);
    final kek = await Primitives.hkdf(
      dhOut,
      salt: Primitives.bytesOf('$chatId|${groupKey.version}'),
      info: Primitives.bytesOf(_wrapInfo),
    );
    final (nonce, merged) = await Primitives.sealRandom(groupKey.key, kek);
    return (Primitives.b64(merged), Primitives.b64(nonce));
  }

  /// Unwrap a group key wrapped for me.
  static Future<GroupKeyEnvelope> unwrap({
    required String wrappedB64,
    required String nonceB64,
    required int version,
    required SimpleKeyPair myIdentity,
    required String wrapperIdentityPubB64,
    required String chatId,
  }) async {
    final dhOut = await Primitives.dh(myIdentity, wrapperIdentityPubB64);
    final kek = await Primitives.hkdf(
      dhOut,
      salt: Primitives.bytesOf('$chatId|$version'),
      info: Primitives.bytesOf(_wrapInfo),
    );
    final plain = await Primitives.open(
        Primitives.unb64(wrappedB64), kek, Primitives.unb64(nonceB64));
    return GroupKeyEnvelope(version, plain);
  }

  /// Per-message AEAD key: HKDF(groupKey, salt=chatId|version,
  /// info=msg). Isolates message keys from wrap keys.
  static Future<Uint8List> messageKey(
      GroupKeyEnvelope groupKey, String chatId) async {
    final k = await Primitives.hkdf(
      groupKey.key,
      salt: Primitives.bytesOf('$chatId|${groupKey.version}'),
      info: Primitives.bytesOf(_msgInfo),
    );
    return k;
  }

  /// Per-message AEAD key for media files (separate context).
  static Future<Uint8List> mediaKey(
      GroupKeyEnvelope groupKey, String chatId) async {
    final k = await Primitives.hkdf(
      groupKey.key,
      salt: Primitives.bytesOf('$chatId|${groupKey.version}'),
      info: Primitives.bytesOf('drs-nexora-group-media-v1'),
    );
    return k;
  }
}

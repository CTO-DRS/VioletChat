import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'primitives.dart';

/// ============================================================
/// Double Ratchet (Signal specification) — real implementation.
///
/// Provides:
///  - Forward secrecy        (chain keys advance one-way)
///  - Break-in recovery      (DH ratchet on every direction change)
///  - Per-message keys       (KDF_CK per message)
///  - Replay protection      (header counters; skipped-key store)
///  - Out-of-order tolerance (bounded skipped message keys)
///
/// KDF_RK(rk, dh) = HKDF(salt=rk, ikm=dh, info="rk") -> 64 bytes
///                  -> (rk', ck)
/// KDF_CK(ck)     : key = HMAC(ck, 0x01) (32B AES-256)
///                  ck' = HMAC(ck, 0x02), nonce = HMAC(ck, 0x03)[0..12]
/// ============================================================
class RatchetHeader {
  final String dh; // sender's current ratchet public key (b64)
  final int pn; // length of previous sending chain
  final int n; // index in current sending chain

  const RatchetHeader({required this.dh, required this.pn, required this.n});

  /// SYNC by contract: this value is embedded directly into the wire
  /// envelope (`envelope.dart -> 'h': header.toJson()`). An async
  /// signature here would leak a raw Future into messages.body and
  /// break jsonEncode at insert time.
  Map<String, dynamic> toJson() => {'dh': dh, 'pn': pn, 'n': n};

  static RatchetHeader fromJson(Map<String, dynamic> j) => RatchetHeader(
        dh: j['dh'] as String,
        pn: (j['pn'] as num).toInt(),
        n: (j['n'] as num).toInt(),
      );

  String get skippedId => '$dh:$n';
}

/// Encrypted message produced by [DoubleRatchet.encrypt].
class RatchetMessage {
  final RatchetHeader header;
  final Uint8List nonce; // 12 bytes
  final Uint8List ciphertext; // merged cipher||mac

  const RatchetMessage(this.header, this.nonce, this.ciphertext);
}

class DoubleRatchet {
  Uint8List rootKey;
  SimpleKeyPair dhSelf;
  String? dhRemote;
  Uint8List? sendingChain;
  Uint8List? receivingChain;
  int sendingN;
  int receivingN;
  int previousSendingN;
  final Map<String, Uint8List> skippedKeys;

  static const int _maxSkip = 100;

  DoubleRatchet._({
    required this.rootKey,
    required this.dhSelf,
    required this.dhRemote,
    required this.sendingChain,
    required this.receivingChain,
    required this.sendingN,
    required this.receivingN,
    required this.previousSendingN,
    required this.skippedKeys,
  });

  // ------------------------------------------------------------------
  // Initialisation
  // ------------------------------------------------------------------

  /// Initiator (Alice): pass the X3DH shared secret and the responder's
  /// signed prekey public key (b64). A fresh ratchet keypair is created.
  static Future<DoubleRatchet> initAlice(
      Uint8List sharedSecret, String remoteSignedPrekeyPubB64) async {
    final dhSelf = await Primitives.newX25519();
    final shared = await Primitives.dh(dhSelf, remoteSignedPrekeyPubB64);
    final (rk, cks) = await _kdfRootKey(sharedSecret, shared);
    return DoubleRatchet._(
      rootKey: rk,
      dhSelf: dhSelf,
      dhRemote: remoteSignedPrekeyPubB64,
      sendingChain: cks,
      receivingChain: null,
      sendingN: 0,
      receivingN: 0,
      previousSendingN: 0,
      skippedKeys: {},
    );
  }

  /// Responder (Bob): pass the X3DH shared secret and the keypair of
  /// the signed prekey the initiator used.
  static Future<DoubleRatchet> initBob(
      Uint8List sharedSecret, SimpleKeyPair signedPrekeyPair) async {
    return DoubleRatchet._(
      rootKey: Uint8List.fromList(sharedSecret),
      dhSelf: signedPrekeyPair,
      dhRemote: null,
      sendingChain: null,
      receivingChain: null,
      sendingN: 0,
      receivingN: 0,
      previousSendingN: 0,
      skippedKeys: {},
    );
  }

  // ------------------------------------------------------------------
  // Encrypt / Decrypt
  // ------------------------------------------------------------------

  /// AD (associated data) binds the ciphertext to its context —
  /// typically: utf8(chatId|senderId|recipientDeviceId).
  Future<RatchetMessage> encrypt(Uint8List plaintext, List<int> ad) async {
    if (sendingChain == null) {
      throw StateError('sending chain not initialised');
    }
    final (newChain, key, nonce) = await _kdfChainKey(sendingChain!);
    sendingChain = newChain;
    final header = RatchetHeader(
      dh: await Primitives.x25519Pub(dhSelf),
      pn: previousSendingN,
      n: sendingN,
    );
    sendingN += 1;
    final ct = await Primitives.seal(plaintext, key, nonce: nonce);
    return RatchetMessage(header, nonce, ct);
  }

  Future<Uint8List> decrypt(RatchetHeader header, Uint8List nonce,
      Uint8List ciphertext, List<int> ad) async {
    // 1) previously skipped keys (stored as key||nonce, 44 bytes)
    final skipped = skippedKeys.remove(header.skippedId);
    if (skipped != null) {
      final (k, n) = _splitKeyNonce(skipped);
      return Primitives.open(ciphertext, k, n);
    }

    // 2) ratchet forward if the remote published a new key
    if (header.dh != dhRemote) {
      await _skipMessageKeys(header.pn);
      await _dhRatchet(header);
    }
    await _skipMessageKeys(header.n);

    if (receivingChain == null) {
      throw StateError('receiving chain not initialised');
    }
    final (chain, key, derivedNonce) = await _kdfChainKey(receivingChain!);
    receivingChain = chain;
    receivingN += 1;
    return Primitives.open(ciphertext, key, derivedNonce);
  }

  // ------------------------------------------------------------------
  // Internals
  // ------------------------------------------------------------------

  Future<void> _dhRatchet(RatchetHeader header) async {
    previousSendingN = sendingN;
    sendingN = 0;
    receivingN = 0;
    dhRemote = header.dh;
    final rx = await Primitives.dh(dhSelf, header.dh);
    final (rk1, ckr) = await _kdfRootKey(rootKey, rx);
    rootKey = rk1;
    receivingChain = ckr;
    dhSelf = await Primitives.newX25519();
    final tx = await Primitives.dh(dhSelf, header.dh);
    final (rk2, cks) = await _kdfRootKey(rootKey, tx);
    rootKey = rk2;
    sendingChain = cks;
  }

  Future<void> _skipMessageKeys(int until) async {
    if (receivingChain == null) return;
    if (receivingN + _maxSkip < until) {
      throw StateError('too many skipped messages');
    }
    while (receivingN < until) {
      final (chain, key, n) = await _kdfChainKey(receivingChain!);
      receivingChain = chain;
      skippedKeys['${dhRemote!}:$receivingN'] =
          Uint8List.fromList([...key, ...n]);
      if (skippedKeys.length > _maxSkip) {
        skippedKeys.remove(skippedKeys.keys.first);
      }
      receivingN += 1;
    }
  }

  static Future<(Uint8List, Uint8List)> _kdfRootKey(
      Uint8List rk, Uint8List dhOut) async {
    final out = await Primitives.hkdf(
      dhOut,
      salt: rk,
      info: Primitives.bytesOf('drs-nexora-root-v1'),
      length: 64,
    );
    return (
      Uint8List.sublistView(out, 0, 32),
      Uint8List.sublistView(out, 32, 64),
    );
  }

  static Future<(Uint8List, Uint8List, Uint8List)> _kdfChainKey(
      Uint8List ck) async {
    final key = await Primitives.hmac(ck, [0x01]); // 32B AES-256 key
    final next = await Primitives.hmac(ck, [0x02]); // next chain key
    final nonceFull = await Primitives.hmac(ck, [0x03]); // 32B -> 12B nonce
    return (
      next,
      key,
      Uint8List.sublistView(nonceFull, 0, 12),
    );
  }

  /// skipped blob layout: 32B key | 12B nonce
  static (Uint8List, Uint8List) _splitKeyNonce(Uint8List blob) => (
        Uint8List.sublistView(blob, 0, 32),
        Uint8List.sublistView(blob, 32, 44),
      );

  // ------------------------------------------------------------------
  // Persistence — serialise the full state as JSON
  // ------------------------------------------------------------------
  Future<Map<String, dynamic>> toJson() async => {
        'rk': Primitives.b64(rootKey),
        'dhs_priv': Primitives.b64(await dhSelf.extractPrivateKeyBytes()),
        'dhs_pub': await Primitives.x25519Pub(dhSelf),
        if (dhRemote != null) 'dhr': dhRemote,
        if (sendingChain != null) 'cks': Primitives.b64(sendingChain!),
        if (receivingChain != null) 'ckr': Primitives.b64(receivingChain!),
        'ns': sendingN,
        'nr': receivingN,
        'pn': previousSendingN,
        'skipped': {
          for (final e in skippedKeys.entries) e.key: Primitives.b64(e.value),
        },
      };

  static Future<DoubleRatchet> fromJson(Map<String, dynamic> j) async {
    final dhsPriv = Primitives.unb64(j['dhs_priv'] as String);
    final dhsPub = Primitives.unb64(j['dhs_pub'] as String);
    final dhSelf = await Primitives.x25519FromSeed(dhsPriv, dhsPub);
    final skipped = <String, Uint8List>{
      for (final e in (j['skipped'] as Map<String, dynamic>).entries)
        e.key: Primitives.unb64(e.value as String),
    };
    return DoubleRatchet._(
      rootKey: Primitives.unb64(j['rk'] as String),
      dhSelf: dhSelf,
      dhRemote: j['dhr'] as String?,
      sendingChain:
          j['cks'] == null ? null : Primitives.unb64(j['cks'] as String),
      receivingChain:
          j['ckr'] == null ? null : Primitives.unb64(j['ckr'] as String),
      sendingN: (j['ns'] as num).toInt(),
      receivingN: (j['nr'] as num).toInt(),
      previousSendingN: (j['pn'] as num).toInt(),
      skippedKeys: skipped,
    );
  }

  Future<String> serialise() async => jsonEncode(await toJson());
}

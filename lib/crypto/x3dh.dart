import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'primitives.dart';

/// ============================================================
/// X3DH — Extended Triple Diffie-Hellman session establishment
/// (Signal specification, adapted).
///
/// Server-published bundle per device:
///   IK  : X25519 identity key        (long-lived, per device)
///   SK  : Ed25519 signing key        (signs SPK)
///   SPK : X25519 signed prekey       (rotated periodically)
///   SPKsig : Ed25519 signature over SPK
///   OPK : X25519 one-time prekey     (optional, single use)
///
/// Initiator (Alice):
///   EK  = fresh X25519 keypair
///   DH1 = DH(IK_A, SPK_B)
///   DH2 = DH(EK_A, IK_B)
///   DH3 = DH(EK_A, SPK_B)
///   DH4 = DH(EK_A, OPK_B)   (only when an OPK was claimed)
///   SK  = HKDF(F || DH1 || DH2 || DH3 || DH4)   F = 0xFF x 32
/// Responder (Bob) computes the same with roles swapped.
/// ============================================================
class PrekeyBundle {
  final String? deviceId; // server-side device row id
  final String identityKey; // X25519 IK (b64)
  final String signingKey; // Ed25519 public (b64)
  final String signedPrekey; // X25519 SPK (b64)
  final String signedPrekeySig; // Ed25519 signature over SPK (b64)
  final int signedPrekeyId;
  final String? oneTimePrekey; // X25519 OPK (b64) or null
  final int? oneTimePrekeyId;

  const PrekeyBundle({
    this.deviceId,
    required this.identityKey,
    required this.signingKey,
    required this.signedPrekey,
    required this.signedPrekeySig,
    required this.signedPrekeyId,
    this.oneTimePrekey,
    this.oneTimePrekeyId,
  });

  factory PrekeyBundle.fromJson(Map<String, dynamic> j) => PrekeyBundle(
        deviceId: j['device_id'] as String?,
        identityKey: j['identity_key'] as String,
        signingKey: j['signing_key'] as String,
        signedPrekey: j['signed_prekey'] as String,
        signedPrekeySig: j['signed_prekey_sig'] as String,
        signedPrekeyId: (j['signed_prekey_id'] as num).toInt(),
        oneTimePrekey: j['one_time_prekey'] as String?,
        oneTimePrekeyId: j['one_time_prekey_id'] == null
            ? null
            : (j['one_time_prekey_id'] as num).toInt(),
      );

  Map<String, dynamic> toJson() => {
        if (deviceId != null) 'device_id': deviceId,
        'identity_key': identityKey,
        'signing_key': signingKey,
        'signed_prekey': signedPrekey,
        'signed_prekey_sig': signedPrekeySig,
        'signed_prekey_id': signedPrekeyId,
        if (oneTimePrekey != null) 'one_time_prekey': oneTimePrekey,
        if (oneTimePrekeyId != null) 'one_time_prekey_id': oneTimePrekeyId,
      };

  /// Verify the Ed25519 signature over the signed prekey.
  Future<bool> verifySignature() => Primitives.verify(
      signingKey, Primitives.unb64(signedPrekey), signedPrekeySig);
}

/// The header carried in the FIRST message of a session so the
/// responder can complete X3DH (a "prekey message").
class X3dhInitiation {
  final String identityKey; // initiator IK pub (b64)
  final String ephemeralKey; // initiator EK pub (b64)
  final int signedPrekeyId; // which SPK of the responder was used
  final int? oneTimePrekeyId; // which OPK was consumed (may be null)

  const X3dhInitiation({
    required this.identityKey,
    required this.ephemeralKey,
    required this.signedPrekeyId,
    this.oneTimePrekeyId,
  });

  Map<String, dynamic> toJson() => {
        'ik': identityKey,
        'ek': ephemeralKey,
        'spk': signedPrekeyId,
        if (oneTimePrekeyId != null) 'opk': oneTimePrekeyId,
      };

  static X3dhInitiation? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return X3dhInitiation(
      identityKey: j['ik'] as String,
      ephemeralKey: j['ek'] as String,
      signedPrekeyId: (j['spk'] as num).toInt(),
      oneTimePrekeyId: j['opk'] == null ? null : (j['opk'] as num).toInt(),
    );
  }
}

class X3dh {
  X3dh._();

  static final Uint8List _fPrefix = Uint8List.fromList(List.filled(32, 0xFF));

  static const String _info = 'drs-nexora-x3dh-v1';

  /// Initiator side. Returns the shared secret (32 bytes) used as the
  /// Double Ratchet root seed plus the ephemeral keypair that MUST be
  /// kept until the session is persisted.
  static Future<(Uint8List, SimpleKeyPair, X3dhInitiation)> initiate(
      PrekeyBundle bundle, SimpleKeyPair myIdentity) async {
    final ok = await bundle.verifySignature();
    if (!ok) {
      throw StateError('SPK signature verification failed — possible MITM');
    }

    final ek = await Primitives.newX25519();

    final dh1 = await Primitives.dh(myIdentity, bundle.signedPrekey);
    final dh2 = await Primitives.dh(ek, bundle.identityKey);
    final dh3 = await Primitives.dh(ek, bundle.signedPrekey);
    Uint8List? dh4;
    if (bundle.oneTimePrekey != null) {
      dh4 = await Primitives.dh(ek, bundle.oneTimePrekey!);
    }

    final sk = await _derive(dh1, dh2, dh3, dh4);

    final initiation = X3dhInitiation(
      identityKey: await Primitives.x25519Pub(myIdentity),
      ephemeralKey: await Primitives.x25519Pub(ek),
      signedPrekeyId: bundle.signedPrekeyId,
      oneTimePrekeyId: bundle.oneTimePrekeyId,
    );

    return (sk, ek, initiation);
  }

  /// Responder side. `mySpk` is the keypair whose public part is
  /// `bundleUsed.signedPrekey`; `myOpk` may be null when no OPK was used.
  static Future<Uint8List> respond({
    required SimpleKeyPair myIdentity,
    required SimpleKeyPair mySpk,
    required X3dhInitiation init,
    SimpleKeyPair? myOpk,
  }) async {
    final dh1 = await Primitives.dh(mySpk, init.identityKey); // DH(SPK_B, IK_A)
    final dh2 = await Primitives.dh(myIdentity, init.ephemeralKey);
    final dh3 = await Primitives.dh(mySpk, init.ephemeralKey);
    Uint8List? dh4;
    if (init.oneTimePrekeyId != null && myOpk != null) {
      dh4 = await Primitives.dh(myOpk, init.ephemeralKey);
    }

    final sk = await _derive(dh1, dh2, dh3, dh4);
    // Sanity check both sides derived a real secret (never all zeros).
    if (_isZero(sk)) {
      throw StateError('X3DH produced an all-zero secret');
    }
    return sk;
  }

  static Future<Uint8List> _derive(
      Uint8List dh1, Uint8List dh2, Uint8List dh3, Uint8List? dh4) async {
    final ikm = <int>[..._fPrefix, ...dh1, ...dh2, ...dh3, ...?dh4];
    final sk = await Primitives.hkdf(
      ikm,
      salt: Uint8List(32),
      info: Primitives.bytesOf(_info),
    );
    return sk;
  }

  static bool _isZero(Uint8List b) => b.every((e) => e == 0);
}

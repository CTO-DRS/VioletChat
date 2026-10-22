import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/config/app_config.dart';
import '../core/logging/app_logger.dart';
import 'primitives.dart';

/// Per-device cryptographic identity stored ONLY in
/// flutter_secure_storage (hardware-backed Keystore on Android).
///
/// Components:
///  deviceId  : UUID — rows on the server are keyed by this
///  ik        : X25519 identity keypair (DM sessions + group wraps)
///  sk        : Ed25519 signing keypair (signs the signed prekey)
///  spk       : X25519 signed prekey pair + its Ed25519 signature
///  opks      : batch of one-time prekey pairs (consumed per session)
///  dbKey     : AES-256 key that encrypts local DB secrets (ratchet state)
class DeviceIdentity {
  final String deviceId;
  final SimpleKeyPair ik;
  final SimpleKeyPair sk;
  final SimpleKeyPair spk;
  final String spkSignature;
  final int spkId;
  final List<(int, SimpleKeyPair)> opks;

  const DeviceIdentity({
    required this.deviceId,
    required this.ik,
    required this.sk,
    required this.spk,
    required this.spkSignature,
    required this.spkId,
    required this.opks,
  });
}

/// Manager that owns loading/creating the identity.
class IdentityManager {
  IdentityManager._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kDeviceId = 'drs_device_id';
  static const _kIkPriv = 'drs_ik_priv';
  static const _kIkPub = 'drs_ik_pub';
  static const _kSkPriv = 'drs_sk_priv';
  static const _kSkPub = 'drs_sk_pub';
  static const _kSpkPriv = 'drs_spk_priv';
  static const _kSpkPub = 'drs_spk_pub';
  static const _kSpkSig = 'drs_spk_sig';
  static const _kSpkId = 'drs_spk_id';
  static const _kOpkPrefix = 'drs_opk_';
  static const _kOpkCounter = 'drs_opk_counter';
  static const _kDbKey = 'drs_db_key';

  static DeviceIdentity? _cached;

  // ----------------------------------------------------------------
  // Keystore resilience — on a small set of devices (and after
  // reinstall/backup-restore) EncryptedSharedPreferences/Keystore
  // reads or writes can THROW PERMANENTLY — or worse, HANG FOREVER
  // without ever completing (observed live on an Infinix/XOS device:
  // eternal splash «جاري تجهيز مفاتيح التشفير…»). try/catch alone
  // cannot cover a future that never resolves, so EVERY storage op
  // carries a hard timeout and the whole load has a watchdog that
  // degrades to an in-memory identity (documented recovery path:
  // server re-registers on next sign-in; nothing is written while
  // degraded, so a recovered Keystore keeps its previous keys).
  // ----------------------------------------------------------------
  static const _opTimeout = Duration(seconds: 8);
  static const _loadTimeout = Duration(seconds: 30);

  static Future<String?> _safeRead(String key) async {
    try {
      return await _storage.read(key: key).timeout(_opTimeout);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _safeWrite(
      {required String key, required String value}) async {
    try {
      await _storage.write(key: key, value: value).timeout(_opTimeout);
    } catch (_) {
      // Keystore unusable/hung — identity lives in memory for this
      // session; next boot regenerates (server re-registers, documented
      // path).
    }
  }

  static Future<List<MapEntry<String, String>>> _safeReadAll() async {
    try {
      return (await _storage.readAll().timeout(_opTimeout)).entries.toList();
    } catch (_) {
      return const [];
    }
  }

  /// Load the identity, or create one if this device never had one.
  ///
  /// Watchdog: if secure storage deadlocks (future never completes —
  /// some OEM Keystore builds), degrade to a pure in-memory identity
  /// instead of hanging the splash forever. No persistence happens in
  /// the degraded path.
  static Future<DeviceIdentity> loadOrCreate() async {
    if (_cached != null) return _cached!;
    try {
      return await _loadOrCreateReal().timeout(_loadTimeout);
    } on TimeoutException {
      AppLogger.w('identity',
          'secure storage timed out (${_loadTimeout.inSeconds}s) — in-memory identity for this session');
      final identity = await _createFresh(persist: false);
      _cached = identity;
      return identity;
    }
  }

  static Future<DeviceIdentity> _loadOrCreateReal() async {
    final deviceId = await _safeRead(_kDeviceId);
    if (deviceId == null) {
      final identity = await _createFresh();
      _cached = identity;
      return identity;
    }

    final ikPriv = await _safeRead(_kIkPriv);
    final ikPub = await _safeRead(_kIkPub);
    final skPriv = await _safeRead(_kSkPriv);
    final skPub = await _safeRead(_kSkPub);
    final spkPriv = await _safeRead(_kSpkPriv);
    final spkPub = await _safeRead(_kSpkPub);
    final spkSig = await _safeRead(_kSpkSig);
    final spkIdStr = await _safeRead(_kSpkId);

    if (ikPriv == null ||
        ikPub == null ||
        skPriv == null ||
        skPub == null ||
        spkPriv == null ||
        spkPub == null ||
        spkSig == null ||
        spkIdStr == null) {
      // Corrupted keystore entry — recreate (documented recovery path).
      final identity = await _createFresh();
      _cached = identity;
      return identity;
    }

    final ik = await Primitives.x25519FromSeed(
        Primitives.unb64(ikPriv), Primitives.unb64(ikPub));
    final sk = await Primitives.ed25519FromSeed(
        Primitives.unb64(skPriv), Primitives.unb64(skPub));
    final spk = await Primitives.x25519FromSeed(
        Primitives.unb64(spkPriv), Primitives.unb64(spkPub));

    // Load remaining (unused) one-time prekeys.
    final opks = <(int, SimpleKeyPair)>[];
    final all = await _safeReadAll();
    for (final e in all) {
      if (e.key.startsWith(_kOpkPrefix)) {
        final id = int.tryParse(e.key.substring(_kOpkPrefix.length));
        if (id == null) continue;
        final parts = e.value.split('|');
        if (parts.length != 2) continue;
        opks.add((
          id,
          await Primitives.x25519FromSeed(
              Primitives.unb64(parts[0]), Primitives.unb64(parts[1])),
        ));
      }
    }
    opks.sort((a, b) => a.$1.compareTo(b.$1));

    _cached = DeviceIdentity(
      deviceId: deviceId,
      ik: ik,
      sk: sk,
      spk: spk,
      spkSignature: spkSig,
      spkId: int.parse(spkIdStr),
      opks: opks,
    );
    return _cached!;
  }

  /// 22-char deviceId made of word characters only.
  ///
  /// Base64 of 16 random bytes is 22 data chars + '==', but the [^\w]
  /// filter strips '+' and '/' as well as the '=' padding. Whenever the
  /// random draw contains one '+' or '/', only 21 chars remain and the
  /// previous bare .substring(0, 22) threw
  ///   RangeError (end): Invalid value: Not in inclusive range 0..21: 22
  /// (~37% of fresh installs). On first boot this crashed BEFORE
  /// _kDeviceId was persisted, so every subsequent boot re-entered
  /// _createFresh and re-crashed — the app could never leave the
  /// splash screen on those devices. Accumulating random base64 until
  /// enough word chars exist makes the length guaranteed.
  static String generateDeviceId() {
    final buf = StringBuffer();
    while (buf.length < 22) {
      buf.write(Primitives.b64(Primitives.randomBytes(16))
          .replaceAll(RegExp(r'[^\w]'), ''));
    }
    return buf.toString().substring(0, 22);
  }

  static Future<DeviceIdentity> _createFresh({bool persist = true}) async {
    final deviceId = generateDeviceId();
    final ik = await Primitives.newX25519();
    final sk = await Primitives.newEd25519();
    final spk = await Primitives.newX25519();

    final spkPub = await Primitives.x25519Pub(spk);
    final sig = await Primitives.sign(sk, Primitives.unb64(spkPub));
    const spkId = 1;

    final opks = <(int, SimpleKeyPair)>[];
    for (var i = 0; i < AppConfig.prekeyBatchSize; i++) {
      opks.add((i + 1, await Primitives.newX25519()));
    }

    if (persist) {
      await _safeWrite(key: _kDeviceId, value: deviceId);
      await _safeWrite(
          key: _kIkPriv,
          value: Primitives.b64(await ik.extractPrivateKeyBytes()));
      await _safeWrite(key: _kIkPub, value: await Primitives.x25519Pub(ik));
      await _safeWrite(
          key: _kSkPriv,
          value: Primitives.b64(await sk.extractPrivateKeyBytes()));
      await _safeWrite(key: _kSkPub, value: await Primitives.ed25519Pub(sk));
      await _safeWrite(
          key: _kSpkPriv,
          value: Primitives.b64(await spk.extractPrivateKeyBytes()));
      await _safeWrite(key: _kSpkPub, value: spkPub);
      await _safeWrite(key: _kSpkSig, value: sig);
      await _safeWrite(key: _kSpkId, value: '$spkId');

      // Persist one-time prekeys as priv|pub (they are local-only secrets).
      for (final (id, kp) in opks) {
        final priv = Primitives.b64(await kp.extractPrivateKeyBytes());
        final pub = await Primitives.x25519Pub(kp);
        await _safeWrite(key: '$_kOpkPrefix$id', value: '$priv|$pub');
      }
      await _safeWrite(key: _kOpkCounter, value: '${AppConfig.prekeyBatchSize}');

      // Local DB encryption key (for ratchet state at rest).
      if (await _safeRead(_kDbKey) == null) {
        await _safeWrite(
            key: _kDbKey, value: Primitives.b64(Primitives.randomBytes(32)));
      }
    }

    return DeviceIdentity(
      deviceId: deviceId,
      ik: ik,
      sk: sk,
      spk: spk,
      spkSignature: sig,
      spkId: spkId,
      opks: opks,
    );
  }

  /// Server-visible public bundle.
  static Future<Map<String, dynamic>> publicBundle(DeviceIdentity id) async {
    return {
      'identity_key': await Primitives.x25519Pub(id.ik),
      'signing_key': await Primitives.ed25519Pub(id.sk),
      'signed_prekey': await Primitives.x25519Pub(id.spk),
      'signed_prekey_sig': id.spkSignature,
      'signed_prekey_id': id.spkId,
      'one_time_prekeys': [
        for (final (oid, kp) in id.opks)
          {'id': oid, 'key': await Primitives.x25519Pub(kp)},
      ],
    };
  }

  /// Remove a consumed OPK locally.
  static Future<void> consumeOpk(int opkId) async {
    try {
      await _storage.delete(key: '$_kOpkPrefix$opkId').timeout(_opTimeout);
    } catch (_) {}
    final id = _cached;
    if (id != null) {
      _cached = DeviceIdentity(
        deviceId: id.deviceId,
        ik: id.ik,
        sk: id.sk,
        spk: id.spk,
        spkSignature: id.spkSignature,
        spkId: id.spkId,
        opks: id.opks.where((e) => e.$1 != opkId).toList(),
      );
    }
  }

  /// AES-256 key used to encrypt ratchet state inside the local DB.
  /// Keystore-resilient: if the value cannot be read or written the
  /// session still gets a usable key (ratchet state may be re-synced).
  static Future<Uint8List> dbKey() async {
    var v = await _safeRead(_kDbKey);
    if (v == null) {
      v = Primitives.b64(Primitives.randomBytes(32));
      await _safeWrite(key: _kDbKey, value: v);
    }
    return Primitives.unb64(v);
  }

  /// Wipe every key on this device (logout / delete account).
  /// Keystore-resilient: deletes what can be deleted, never throws.
  static Future<void> wipe() async {
    final List<MapEntry<String, String>> all;
    try {
      all = await _safeReadAll();
    } catch (_) {
      return;
    }
    for (final e in all) {
      if (e.key.startsWith('drs_')) {
        try {
          await _storage.delete(key: e.key).timeout(_opTimeout);
        } catch (_) {}
      }
    }
    _cached = null;
  }
}

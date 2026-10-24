import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/key_value_store.dart';

/// Device-local PIN app lock (v0.1.14, hardened 2026-10-25).
///
/// The PIN never leaves the phone: only a salted KDF hash is kept,
/// inside Android Keystore-encrypted storage. It is NOT part of the
/// synced UserSettings — a fresh install simply has no PIN (documented
/// behaviour, mirrors WhatsApp's device-local lock material).
///
/// Hardening (audit 2026-10-25):
///  - The verifier is now PBKDF2-HMAC-SHA256 (30k iterations) instead
///    of a single SHA-256 round. The old scheme left a 10^4–10^6 keyspace
///    that one offline pass over a leaked keystore file cracks instantly;
///    PBKDF2 makes each guess ~30k times more expensive.
///  - The attempt throttle is now PERSISTENT in keystore storage
///    (attempts + lock-until epoch ms), so restarting the app no longer
///    resets the brute-force counter.
///  - Transparent upgrade: a legacy single-round hash still verifies
///    and is re-stored in the hardened format on the next successful
///    verify.
///
/// Fail-safe semantics match the biometric lock: any storage error
/// reads as "no PIN", so a keystore hiccup can never lock the user out
/// of a working app.
class PinLockService {
  PinLockService(this._store);

  static PinLockService? _i;
  static PinLockService get I => _i ??= PinLockService(SecureKeyValueStore());

  /// Tests inject their own service instance.
  static set instance(PinLockService s) => _i = s;

  final KeyValueStore _store;

  static const _hashKey = 'violet.pin.hash.v1';
  static const _saltKey = 'violet.pin.salt.v1';
  static const _lenKey = 'violet.pin.len.v1';
  static const _failsKey = 'violet.pin.fails.v2';
  static const _lockUntilKey = 'violet.pin.lockUntil.v2';

  /// Hardened KDF: 30k PBKDF2-HMAC-SHA256 rounds ≈ a few hundred ms on
  /// mid-range hardware — imperceptible once, brutal for brute force.
  static const _pbkdf2Iterations = 30000;
  static final Pbkdf2 _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _pbkdf2Iterations,
    bits: 256,
  );
  static final _rng = Random.secure();

  // Attempt throttle — persisted (fix: audit 2026-10-25). Loaded lazily
  // from the keystore on first use so a restart does NOT reset it.
  int _fails = 0;
  DateTime? _lockUntil;
  bool _throttleLoaded = false;
  static const _maxFails = 5;
  static const _coolDown = Duration(seconds: 30);

  Future<void> _ensureThrottleLoaded() async {
    if (_throttleLoaded) return;
    _throttleLoaded = true;
    try {
      final f = int.tryParse(await _store.read(_failsKey) ?? '');
      final l = int.tryParse(await _store.read(_lockUntilKey) ?? '');
      if (f != null && f > 0) _fails = f;
      if (l != null && l > 0) {
        final until = DateTime.fromMillisecondsSinceEpoch(l);
        _lockUntil = until.isAfter(DateTime.now()) ? until : null;
        if (_lockUntil == null) await _store.delete(_lockUntilKey);
      }
    } catch (_) {
      // Fail-safe: throttle state unreadable → treat as clean slate.
      _fails = 0;
      _lockUntil = null;
    }
  }

  Future<void> _persistThrottle() async {
    try {
      if (_fails > 0) {
        await _store.write(_failsKey, '$_fails');
      } else {
        await _store.delete(_failsKey);
      }
      if (_lockUntil != null) {
        await _store.write(_lockUntilKey, '${_lockUntil!.millisecondsSinceEpoch}');
      } else {
        await _store.delete(_lockUntilKey);
      }
    } catch (_) {
      // Best-effort persistence — in-memory state still applies.
    }
  }

  bool get lockedOut => _lockUntil != null && DateTime.now().isBefore(_lockUntil!);

  /// Seconds left in the current cool-down (0 when none).
  int get lockoutSecsRemaining {
    if (!lockedOut) return 0;
    return _lockUntil!.difference(DateTime.now()).inSeconds + 1;
  }

  Future<bool> isPinSet() async => (await _store.read(_hashKey)) != null;

  /// Stored PIN length (4–6), or null when no PIN is set.
  Future<int?> pinLength() async =>
      int.tryParse(await _store.read(_lenKey) ?? '');

  /// Set (or replace) the PIN. [pin] must be 4–6 digits.
  /// Throws [ArgumentError] on invalid input — callers validate first.
  Future<void> setPin(String pin) async {
    if (!_isValid(pin)) throw ArgumentError('PIN must be 4-6 digits');
    final saltBytes =
        List<int>.generate(16, (_) => _rng.nextInt(256));
    final hash = await _kdfHash(saltBytes, pin);
    await _store.write(_saltKey, _hex(saltBytes));
    await _store.write(_hashKey, 'v2:$_pbkdf2Iterations:${_hex(saltBytes)}:$hash');
    await _store.write(_lenKey, pin.length.toString());
    _fails = 0;
    _lockUntil = null;
    await _persistThrottle();
  }

  /// Raw verify (no throttle) — used by the settings change/remove flow.
  /// Transparently upgrades a legacy single-round hash to PBKDF2.
  Future<bool> verifyPin(String pin) async {
    final stored = await _store.read(_hashKey);
    if (stored == null) return false;
    if (!_isValid(pin)) return false;

    if (stored.startsWith('v2:')) {
      // Hardened format: v2:<iterations>:<saltHex>:<hashHex>
      final parts = stored.split(':');
      if (parts.length != 4) return false;
      final iterations = int.tryParse(parts[1]);
      final saltBytes = _unhex(parts[2]);
      final expected = parts[3];
      if (iterations == null || saltBytes == null) return false;
      final hash = await _pbkdf2(saltBytes, utf8.encode('${parts[2]}:$pin'),
          iterations);
      return _constEq(expected, hash);
    }

    // Legacy format (v0.1.14): plain salted SHA-256, salt stored
    // separately. Verify, then UPGRADE in place to the hardened KDF.
    final salt = await _store.read(_saltKey);
    if (salt == null) return false;
    final digest = await Sha256().hash(utf8.encode('$salt:$pin'));
    final legacyHex = _hex(digest.bytes);
    if (!_constEq(stored, legacyHex)) return false;
    try {
      final saltBytes = _unhex(salt) ?? utf8.encode(salt);
      final hash = await _kdfHash(saltBytes, pin);
      await _store.write(
          _hashKey, 'v2:$_pbkdf2Iterations:${_hex(saltBytes)}:$hash');
      AppLogger.i('pin_lock',
          'legacy PIN hash upgraded to PBKDF2 ($_pbkdf2Iterations rounds)');
    } catch (_) {
      // Upgrade is best-effort; verification result stands.
    }
    return true;
  }

  /// Throttled verify used by the lock screen: 5 wrong entries start a
  /// 30 s cool-down (persisted across restarts). Returns false while
  /// locked out without even hashing (cheap brute-force brake).
  Future<bool> verifyWithThrottle(String pin) async {
    await _ensureThrottleLoaded();
    if (lockedOut) return false;
    final ok = await verifyPin(pin);
    if (ok) {
      _fails = 0;
      _lockUntil = null;
      await _persistThrottle();
      return true;
    }
    _fails++;
    if (_fails >= _maxFails) {
      _lockUntil = DateTime.now().add(_coolDown);
      _fails = 0;
      AppLogger.w('pin_lock', '5 wrong PIN entries — cool-down engaged');
    }
    await _persistThrottle();
    return false;
  }

  Future<void> clearPin() async {
    await _store.delete(_hashKey);
    await _store.delete(_saltKey);
    await _store.delete(_lenKey);
    await _store.delete(_failsKey);
    await _store.delete(_lockUntilKey);
    _fails = 0;
    _lockUntil = null;
  }

  static bool _isValid(String pin) =>
      pin.length >= 4 && pin.length <= 6 && RegExp(r'^\d+$').hasMatch(pin);

  static Future<String> _kdfHash(List<int> saltBytes, String pin) =>
      _pbkdf2(saltBytes, utf8.encode('${_hex(saltBytes)}:$pin'),
          _pbkdf2Iterations);

  static Future<String> _pbkdf2(
      List<int> salt, List<int> ikm, int iterations) async {
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: salt,
    );
    return _hex(await key.extractBytes());
  }

  /// Constant-time-ish hex compare (lengths are fixed anyway).
  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int>? _unhex(String s) {
    if (s.isEmpty || s.length.isOdd) return null;
    try {
      return List<int>.generate(
          s.length ~/ 2, (i) => int.parse(s.substring(i * 2, i * 2 + 2), radix: 16));
    } catch (_) {
      return null;
    }
  }
}

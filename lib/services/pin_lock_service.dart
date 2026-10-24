import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../core/logging/app_logger.dart';
import '../core/storage/key_value_store.dart';

/// Device-local PIN app lock (v0.1.14).
///
/// The PIN never leaves the phone: only a salted SHA-256 hash is kept,
/// inside Android Keystore-encrypted storage. It is NOT part of the
/// synced UserSettings — a fresh install simply has no PIN (documented
/// behaviour, mirrors WhatsApp's device-local lock material).
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

  static final _sha = Sha256();
  static final _rng = Random.secure();

  // Attempt throttle (in-memory, per process — best-effort, the real
  // protection is the salted hash in keystore storage).
  int _fails = 0;
  DateTime? _lockUntil;
  static const _maxFails = 5;
  static const _coolDown = Duration(seconds: 30);

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
    // 8 random bytes of salt → rainbow tables are pointless.
    final salt = List<int>.generate(8, (_) => _rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final hash = await _hash(salt, pin);
    await _store.write(_saltKey, salt);
    await _store.write(_hashKey, hash);
    await _store.write(_lenKey, pin.length.toString());
    _fails = 0;
    _lockUntil = null;
  }

  /// Raw verify (no throttle) — used by the settings change/remove flow.
  Future<bool> verifyPin(String pin) async {
    final salt = await _store.read(_saltKey);
    final stored = await _store.read(_hashKey);
    if (salt == null || stored == null) return false;
    if (!_isValid(pin)) return false;
    final hash = await _hash(salt, pin);
    // Constant-time-ish compare (lengths are fixed anyway).
    var diff = 0;
    for (var i = 0; i < stored.length; i++) {
      diff |= stored.codeUnitAt(i) ^ hash.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Throttled verify used by the lock screen: 5 wrong entries start a
  /// 30 s cool-down. Returns false while locked out without even
  /// hashing (cheap brute-force brake).
  Future<bool> verifyWithThrottle(String pin) async {
    if (lockedOut) return false;
    final ok = await verifyPin(pin);
    if (ok) {
      _fails = 0;
      _lockUntil = null;
      return true;
    }
    _fails++;
    if (_fails >= _maxFails) {
      _lockUntil = DateTime.now().add(_coolDown);
      _fails = 0;
      AppLogger.w('pin_lock', '5 wrong PIN entries — cool-down engaged');
    }
    return false;
  }

  Future<void> clearPin() async {
    await _store.delete(_hashKey);
    await _store.delete(_saltKey);
    await _store.delete(_lenKey);
    _fails = 0;
    _lockUntil = null;
  }

  static bool _isValid(String pin) =>
      pin.length >= 4 && pin.length <= 6 && RegExp(r'^\d+$').hasMatch(pin);

  static Future<String> _hash(String salt, String pin) async {
    final digest = await _sha.hash(utf8.encode('$salt:$pin'));
    return digest.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

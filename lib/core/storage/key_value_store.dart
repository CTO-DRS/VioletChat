import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Tiny key/value abstraction over the device keystore.
///
/// v0.1.14 — introduced so device-local secrets (PIN lock hash,
/// scheduled-message queue) can live in Android Keystore-backed
/// storage while staying unit-testable: tests inject
/// [MemoryKeyValueStore], production uses [SecureKeyValueStore].
///
/// Everything written here is device-only — nothing in this store is
/// ever synced to the server (by design, see SECURITY semantics).
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> wipePrefix(String prefix);
}

/// Keystore-backed implementation (encrypted shared preferences on
/// Android / keychain on iOS). Values never leave the device.
class SecureKeyValueStore implements KeyValueStore {
  const SecureKeyValueStore();

  static const FlutterSecureStorage _s = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) async {
    try {
      return await _s.read(key: key);
    } catch (_) {
      return null; // keystore hiccup reads as "absent" — never crash
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _s.write(key: key, value: value);
    } catch (_) {
      // Best effort — callers treat a failed write as "not persisted".
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _s.delete(key: key);
    } catch (_) {}
  }

  @override
  Future<void> wipePrefix(String prefix) async {
    try {
      final all = await _s.readAll();
      for (final key in all.keys) {
        if (key.startsWith(prefix)) await _s.delete(key: key);
      }
    } catch (_) {}
  }
}

/// In-memory implementation for tests only.
class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async => _m[key] = value;

  @override
  Future<void> delete(String key) async => _m.remove(key);

  @override
  Future<void> wipePrefix(String prefix) async {
    _m.removeWhere((k, _) => k.startsWith(prefix));
  }
}

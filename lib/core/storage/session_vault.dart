import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// خزنة جلسة المراسلة (audit 2026-10-25).
///
/// WHY THIS EXISTS: supabase_flutter's default `LocalStorage` persists
/// the whole session JSON — access token AND long-lived refresh token —
/// into SharedPreferences, which is a PLAINTEXT XML file on disk (and
/// included in device backups unless excluded). The messaging
/// credential that actually operates day-to-day was therefore readable
/// at rest outside the Keystore.
///
/// WHAT CHANGES: the session JSON now lives in flutter_secure_storage
/// (hardware-backed EncryptedSharedPreferences on Android — the same
/// trust level the identity keys and the messaging key already use).
///
/// MIGRATION (one-way, transparent): on first `initialize()` the vault
/// looks for a session left behind by the old SharedPreferences
/// default under the SAME key, copies it into the vault and DELETES
/// the plaintext copy. No user-visible sign-out, no data loss.
///
/// WHY THIS REPLACES PASSWORD ROTATION (honest design note): rotating
/// the Supabase account password per device was evaluated and
/// REJECTED — the messaging account has no password-reset channel,
/// so any rotation permanently breaks typed-password recovery from
/// every OTHER device (a second device that loses its stored secret
/// could never sign back in). The refresh token stored here is the
/// better credential: GoTrue rotates it server-side on every refresh,
/// it is single-use and revocable — a leaked token has a tiny validity
/// window, unlike the account password. The account password remains
/// in Keystore (v0.1.8 messaging-key bridge) ONLY as a last-resort
/// fallback for when the session itself is gone — no longer the
/// credential operating the day-to-day session.
class SecureVaultLocalStorage extends LocalStorage {
  SecureVaultLocalStorage({required this.persistSessionKey});

  /// Must match the default derivation so the legacy SharedPreferences
  /// entry is found and superseded:
  /// `sb-<host-first-label>-auth-token` (see supabase_flutter 2.8.4,
  /// Supabase.initialize default).
  final String persistSessionKey;

  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  bool _migrated = false;

  @override
  Future<void> initialize() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final alreadyVaulted = await _readRaw() != null;
      if (alreadyVaulted) return;
      final prefs = await SharedPreferences.getInstance();
      final legacy = prefs.getString(persistSessionKey);
      if (legacy == null || legacy.isEmpty) return;
      await _secure.write(key: persistSessionKey, value: legacy);
      // Only after the vault copy succeeded — never destroy the only
      // copy of a working session.
      await prefs.remove(persistSessionKey);
    } catch (_) {
      // Migration is best-effort: a keystore hiccup degrades to "no
      // persisted session" (same contract as every other keystore read
      // in this app — read as absent, never crash boot).
    }
  }

  Future<String?> _readRaw() async {
    try {
      return await _secure.read(key: persistSessionKey);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasAccessToken() async => (await _readRaw()) != null;

  /// NOTE (library contract): despite the name, this returns the RAW
  /// persisted session JSON — SupabaseAuth feeds it straight into
  /// `auth.setInitialSession(...)` / `auth.recoverSession(...)`.
  @override
  Future<String?> accessToken() => _readRaw();

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _secure.write(key: persistSessionKey, value: persistSessionString);
    } catch (_) {
      // Best effort — same contract as SecureKeyValueStore: a failed
      // write means "not persisted this time"; sign-in itself already
      // succeeded and must not be interrupted by a keystore hiccup.
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _secure.delete(key: persistSessionKey);
    } catch (_) {
      // Same contract — sign-out proceeds even if the keystore delete
      // fails; the leftover entry stays keystore-encrypted on-device.
    }
  }

  /// Replicates the library's default key derivation for a given
  /// Supabase URL, so the app can wire the vault with exactly the key
  /// the previous plaintext default used.
  static String keyFor(String supabaseUrl) =>
      'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';
}

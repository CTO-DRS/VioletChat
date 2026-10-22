import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../crypto/primitives.dart';
import '../../core/config/app_config.dart';

/// Local database (offline-first cache + crypto state).
///
/// SECURITY: the `sessions` table stores ratchet state ENCRYPTED at
/// rest with a key held in flutter_secure_storage (see IdentityManager
/// .dbKey). Decrypted text caches are local-only and wiped on logout.
class LocalDatabase {
  LocalDatabase._();

  static Database? _db;
  static Uint8List? _dbKey;

  static Future<Database> get instance async {
    _db ??= await _open();
    return _db!;
  }

  static Future<Uint8List> dbKey() async {
    if (_dbKey == null) {
      // Imported lazily to keep this file independent of identity.dart
      // initialisation order.
      final v = await IdentityBridge.dbKey();
      _dbKey = v;
    }
    return _dbKey!;
  }

  static Future<Database> _open() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'drs_nexora.db');
    try {
      return await _openAt(path);
    } catch (_) {
      // SELF-HEAL: a corrupt database file (e.g. interrupted write on a
      // previous install/upgrade) previously killed boot with an eternal
      // black screen. The file is local CACHE — recreate it. Ratchet
      // state is re-synced from sessions on next sign-in.
      await deleteFile();
      return _openAt(path);
    }
  }

  static Future<Database> _openAt(String path) => openDatabase(
        path,
        version: 3,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onUpgrade: (db, oldVersion, newVersion) async {
          // v2 (v0.1.0): forwarded_from on the local cache — rendered
          // as a «مُعاد توجيهه» chip. Old rows keep null (no chip).
          if (oldVersion < 2) {
            await db.execute(
                'ALTER TABLE messages_cache ADD COLUMN forwarded_from TEXT');
          }
          // v3 (v0.1.0): server-stamped expiry (disappearing messages)
          // + my-star flag for the «الرسائل المحفوظة» screen.
          if (oldVersion < 3) {
            await db

                .execute('ALTER TABLE messages_cache ADD COLUMN expires_at TEXT');
            await db.execute(
                'ALTER TABLE messages_cache ADD COLUMN starred INTEGER NOT NULL DEFAULT 0');
          }
        },
        onCreate: (db, version) async {
          final batch = db.batch();
          batch.execute('''
          CREATE TABLE kv (
            k TEXT PRIMARY KEY,
            v TEXT NOT NULL
          )''');
          batch.execute('''
          CREATE TABLE chats_cache (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            json TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )''');
          batch.execute('''
          CREATE TABLE messages_cache (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            client_msg_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT,
            media_json TEXT,
            body_json TEXT,
            reply_to TEXT,
            reply_preview TEXT,
            forwarded_from TEXT,
            expires_at TEXT,
            starred INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            server_at TEXT NOT NULL DEFAULT '',
            edited_at TEXT,
            deleted_for_all INTEGER NOT NULL DEFAULT 0,
            key_version INTEGER NOT NULL DEFAULT 0,
            state TEXT NOT NULL DEFAULT 'sent',
            failure_reason TEXT,
            decrypted INTEGER NOT NULL DEFAULT 1,
            outgoing INTEGER NOT NULL DEFAULT 0
          )''');
          batch.execute(
              'CREATE INDEX idx_messages_chat ON messages_cache (chat_id, created_at)');
          batch.execute(
              'CREATE INDEX idx_messages_text ON messages_cache (text)');
          batch.execute(
              'CREATE UNIQUE INDEX idx_messages_cmid ON messages_cache (client_msg_id)');
          batch.execute('''
          CREATE TABLE outbox (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            action TEXT NOT NULL,
            payload TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            next_attempt_at TEXT NOT NULL,
            last_error TEXT
          )''');
          batch.execute(
              'CREATE INDEX idx_outbox_next ON outbox (next_attempt_at)');
          batch.execute('''
          CREATE TABLE sessions (
            chat_id TEXT NOT NULL,
            peer_device_id TEXT NOT NULL,
            state_enc TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (chat_id, peer_device_id)
          )''');
          batch.execute('''
          CREATE TABLE group_keys (
            chat_id TEXT NOT NULL,
            version INTEGER NOT NULL,
            key_enc TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (chat_id, version)
          )''');
          batch.execute('''
          CREATE TABLE receipts_cache (
            message_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            delivered_at TEXT,
            read_at TEXT,
            PRIMARY KEY (message_id, user_id)
          )''');
          batch.execute('''
          CREATE TABLE reactions_cache (
            message_id TEXT NOT NULL,
            user_id TEXT NOT NULL,
            emoji TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (message_id, user_id)
          )''');
          await batch.commit(noResult: true);
        },
      );

  // ------------------------------------------------------------------
  // KV helpers (sync cursors, settings cache...)
  // ------------------------------------------------------------------
  static Future<String?> kvGet(String key) async {
    final db = await instance;
    final rows = await db.query('kv', where: 'k = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['v'] as String?;
  }

  static Future<void> kvSet(String key, String value) async {
    final db = await instance;
    await db.insert('kv', {'k': key, 'v': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> kvRemove(String key) async {
    final db = await instance;
    await db.delete('kv', where: 'k = ?', whereArgs: [key]);
  }

  /// All key/value pairs whose key starts with [prefix] (v0.1.0 —
  /// used by the chats list to surface per-chat drafts).
  static Future<Map<String, String>> kvByPrefix(String prefix) async {
    final db = await instance;
    final rows =
        await db.query('kv', where: 'k LIKE ?', whereArgs: ['$prefix%']);
    return {
      for (final r in rows)
        if (r['v'] != null) r['k'] as String: r['v'] as String,
    };
  }

  // ------------------------------------------------------------------
  // Encryption helpers for secret blobs (ratchet state, group keys)
  // ------------------------------------------------------------------
  static Future<String> sealJson(Map<String, dynamic> json) async {
    final key = await dbKey();
    final (nonce, merged) =
        await Primitives.sealRandom(Primitives.bytesOf(jsonEncode(json)), key);
    return '${Primitives.b64(nonce)}|${Primitives.b64(merged)}';
  }

  static Future<Map<String, dynamic>?> openJson(String blob) async {
    try {
      final parts = blob.split('|');
      if (parts.length != 2) return null;
      final key = await dbKey();
      final plain = await Primitives.open(
          Primitives.unb64(parts[1]), key, Primitives.unb64(parts[0]));
      return jsonDecode(Primitives.utf8s(plain)) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // Wipe (logout / account deletion)
  // ------------------------------------------------------------------
  static Future<void> wipeAll() async {
    final db = await instance;
    await db.delete('messages_cache');
    await db.delete('chats_cache');
    await db.delete('outbox');
    await db.delete('sessions');
    await db.delete('group_keys');
    await db.delete('receipts_cache');
    await db.delete('reactions_cache');
    await db.delete('kv');
  }

  // Metadata constants used by sync engine.
  static int get pageSize => AppConfig.pageSize;

  /// Delete the database file (and journals) from disk. Used by the
  /// self-healing open path and the bootstrap "reset local crypto"
  /// recovery action. Safe to call when the file does not exist.
  static Future<void> deleteFile() async {
    _db = null;
    _dbKey = null;
    final dir = await getApplicationDocumentsDirectory();
    final base = p.join(dir.path, 'drs_nexora.db');
    for (final path in [base, '$base-journal', '$base-wal', '$base-shm']) {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}

/// Bridge to avoid a circular import between LocalDatabase and
/// IdentityManager: identity owns the DB encryption key.
class IdentityBridge {
  static Future<Uint8List> Function()? _provider;
  static void register(Future<Uint8List> Function() provider) =>
      _provider = provider;
  static Future<Uint8List> dbKey() async {
    final p = _provider;
    if (p == null) throw StateError('IdentityBridge not registered');
    return p();
  }
}

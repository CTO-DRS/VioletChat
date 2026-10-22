import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sqflite/sqflite.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../crypto/double_ratchet.dart';
import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import '../crypto/primitives.dart';
import '../crypto/x3dh.dart';
import '../core/storage/local_database.dart';
import '../data/repositories/key_repository.dart';

/// Owns Double Ratchet sessions.
///
/// Sessions are keyed by (chatId, peerDeviceId) and stored ENCRYPTED
/// in the local database. X3DH establishment is performed lazily:
///  - outgoing: against every non-revoked device of the peer
///  - incoming: from the x3dh block carried by the first message
class SessionManager {
  final SupabaseClient client;
  final KeyRepository keys;
  final DeviceIdentity identity;

  SessionManager(this.client, this.keys, this.identity);

  static const String _adPrefix = 'drs-nexora-dm-v1';

  /// First message of a session must carry its X3DH initiation block.
  final Map<String, X3dhInitiation> _pendingInit = {};

  // ------------------------------------------------------------------
  // Persistence (state encrypted at rest with the secure-storage key)
  // ------------------------------------------------------------------
  Future<DoubleRatchet?> _load(String chatId, String peerDeviceId) async {
    final db = await LocalDatabase.instance;
    final rows = await db.query('sessions',
        where: 'chat_id = ? AND peer_device_id = ?',
        whereArgs: [chatId, peerDeviceId]);
    if (rows.isEmpty) return null;
    final json =
        await LocalDatabase.openJson(rows.first['state_enc'] as String);
    if (json == null) return null;
    return DoubleRatchet.fromJson(json);
  }

  Future<void> _save(
      String chatId, String peerDeviceId, DoubleRatchet session) async {
    final db = await LocalDatabase.instance;
    await db.insert(
      'sessions',
      {
        'chat_id': chatId,
        'peer_device_id': peerDeviceId,
        'state_enc': await LocalDatabase.sealJson(await session.toJson()),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteAllSessions(String chatId) async {
    final db = await LocalDatabase.instance;
    await db.delete('sessions', where: 'chat_id = ?', whereArgs: [chatId]);
  }

  // ------------------------------------------------------------------
  // Establishment
  // ------------------------------------------------------------------

  /// Create sessions with every active device of [peerUserId] that
  /// does not have one yet. Returns deviceId -> session.
  Future<Map<String, DoubleRatchet>> ensureOutgoing(
      String chatId, String peerUserId) async {
    final bundles = await keys.fetchBundles(peerUserId);
    final map = <String, DoubleRatchet>{};
    for (final bundle in bundles) {
      final peerDevice = bundle.deviceId;
      if (peerDevice == null) continue;
      final existing = await _load(chatId, peerDevice);
      if (existing != null) {
        map[peerDevice] = existing;
        continue;
      }
      final (sk, _, init) = await X3dh.initiate(bundle, identity.ik);
      final session = await DoubleRatchet.initAlice(sk, bundle.signedPrekey);
      _pendingInit['$chatId|$peerDevice'] = init;
      await _save(chatId, peerDevice, session);
      map[peerDevice] = session;
    }
    return map;
  }

  /// Build a session from an incoming prekey message if needed.
  Future<DoubleRatchet> ensureIncoming(
      String chatId, String peerDeviceId, Map<String, dynamic> entry) async {
    final existing = await _load(chatId, peerDeviceId);
    if (existing != null) return existing;

    final init = X3dhInitiation.fromJson(entry['x3'] as Map<String, dynamic>?);
    if (init == null) {
      throw StateError('no session and no X3DH block — cannot decrypt');
    }

    // The initiator used MY spkId / opkId — resolve the keypairs.
    final spk = identity.spk;
    SimpleKeyPair? opk;
    final opkId = init.oneTimePrekeyId;
    if (opkId != null) {
      for (final (id, kp) in identity.opks) {
        if (id == opkId) {
          opk = kp;
          break;
        }
      }
    }

    final sk = await X3dh.respond(
      myIdentity: identity.ik,
      mySpk: spk,
      init: init,
      myOpk: opk,
    );
    final session = await DoubleRatchet.initBob(sk, spk);
    await _save(chatId, peerDeviceId, session);
    if (opkId != null) await IdentityManager.consumeOpk(opkId);
    return session;
  }

  // ------------------------------------------------------------------
  // Encrypt / decrypt one DM payload
  // ------------------------------------------------------------------

  /// Encrypt [payload] for every device of the peer. Returns the
  /// envelope `e` entries.
  Future<List<Map<String, dynamic>>> encryptDirect(
      String chatId, String peerUserId, List<int> payload) async {
    final sessions = await ensureOutgoing(chatId, peerUserId);
    final ad = _ad(chatId);
    final entries = <Map<String, dynamic>>[];
    for (final e in sessions.entries) {
      final peerDevice = e.key;
      final session = e.value;
      final msg = await session.encrypt(Uint8List.fromList(payload), ad);
      final init = _pendingInit.remove('$chatId|$peerDevice');
      entries.add(MessageEnvelope.directEntry(
        deviceId: peerDevice,
        init: init,
        header: msg.header,
        nonce: msg.nonce,
        ciphertext: msg.ciphertext,
      ));
    }
    return entries;
  }

  Future<Uint8List> decryptDirect(
      String chatId, String senderDeviceId, Map<String, dynamic> entry) async {
    final session = await ensureIncoming(chatId, senderDeviceId, entry);
    final ad = _ad(chatId);
    final plain = await session.decrypt(
      RatchetHeader.fromJson(entry['h'] as Map<String, dynamic>),
      Primitives.unb64(entry['n'] as String),
      Primitives.unb64(entry['c'] as String),
      ad,
    );
    await _save(chatId, senderDeviceId, session);
    return plain;
  }

  List<int> _ad(String chatId) =>
      Primitives.bytesOf('$_adPrefix|$chatId|${identity.deviceId}');
}

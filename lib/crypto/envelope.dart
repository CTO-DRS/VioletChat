import 'dart:convert';
import 'dart:typed_data';

import 'double_ratchet.dart';
import 'x3dh.dart';

/// ============================================================
/// Message envelope — the JSON stored in messages.body (jsonb).
///
/// The server only ever sees ciphertext + routing metadata.
///
/// Direct chat (ratchet, per recipient DEVICE):
/// {
///   "v": 1,
///   "t": "d",
///   "sd": "<senderDeviceId>",
///   "e": [
///     { "d": "<recipientDeviceId>",
///       "x3": {x3dh initiation} | absent,
///       "h": {ratchet header},
///       "n": "<nonce b64>",
///       "c": "<cipher||mac b64>" }
///   ]
/// }
///
/// Group chat (versioned group key):
/// {
///   "v": 1,
///   "t": "g",
///   "sd": "<senderDeviceId>",
///   "kv": <group key version>,
///   "n": "<nonce b64>",
///   "c": "<cipher||mac b64>"
/// }
///
/// System messages (public facts, no content to protect):
/// { "v":1, "t":"s", "sd":"...", "sys": "<text>" }
///
/// INNER PAYLOAD (the decrypted plaintext JSON):
/// { "kind": "text"|"media",
///   "text": "...",
///   "media": { "type":"image|audio|video|file", "path": "...",
///              "size": n, "mime": "...", "name": "...",
///              "w": n, "h": n, "dur": n,
///              "fkey": "<b64>", "fnonce": "<b64>",
///              "thumb": "<path>", "tkey": "<b64>", "tnonce": "<b64>" },
///   "replyTo": "<messageId>" | null }
/// ============================================================
class MessageEnvelope {
  static const int version = 1;

  static Map<String, dynamic> direct({
    required String senderDeviceId,
    required List<Map<String, dynamic>> entries,
  }) =>
      {'v': version, 't': 'd', 'sd': senderDeviceId, 'e': entries};

  static Map<String, dynamic> directEntry({
    required String deviceId,
    X3dhInitiation? init,
    required RatchetHeader header,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) =>
      {
        'd': deviceId,
        if (init != null) 'x3': init.toJson(),
        'h': header.toJson(),
        'n': _b64(nonce),
        'c': _b64(ciphertext),
      };

  static Map<String, dynamic> group({
    required String senderDeviceId,
    required int keyVersion,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) =>
      {
        'v': version,
        't': 'g',
        'sd': senderDeviceId,
        'kv': keyVersion,
        'n': _b64(nonce),
        'c': _b64(ciphertext),
      };

  static Map<String, dynamic> system({
    required String senderDeviceId,
    required String text,
  }) =>
      {'v': version, 't': 's', 'sd': senderDeviceId, 'sys': text};

  static bool isDirect(Map<String, dynamic> e) => e['t'] == 'd';
  static bool isGroup(Map<String, dynamic> e) => e['t'] == 'g';
  static bool isSystem(Map<String, dynamic> e) => e['t'] == 's';

  /// The per-device entry addressed to [myDeviceId], or null.
  static Map<String, dynamic>? entryFor(
      Map<String, dynamic> envelope, String myDeviceId) {
    final entries = envelope['e'];
    if (entries is! List) return null;
    for (final e in entries) {
      if (e is Map<String, dynamic> && e['d'] == myDeviceId) return e;
    }
    return null;
  }

  static int groupKeyVersion(Map<String, dynamic> e) =>
      (e['kv'] as num?)?.toInt() ?? 0;

  static String senderDevice(Map<String, dynamic> e) =>
      (e['sd'] as String?) ?? '';

  static String systemText(Map<String, dynamic> e) =>
      (e['sys'] as String?) ?? '';
}

String _b64(List<int> bytes) => base64Encode(bytes);

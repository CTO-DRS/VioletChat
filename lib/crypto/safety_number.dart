import 'primitives.dart';

/// Safety number — a human-verifiable fingerprint of a conversation
/// (same idea as WhatsApp/Signal safety numbers).
///
/// Computed as SHA-256 over the sorted pair of identity keys
/// (or a single key for self-check), rendered as 12 groups of 5
/// decimal digits: "01234 56789 ...".
class SafetyNumber {
  SafetyNumber._();

  static Future<String> forPair(String keyA, String keyB) async {
    final keys = [keyA, keyB]..sort();
    final digest = await Primitives.hash(
        Primitives.bytesOf('drs-nexora-safety|${keys.join('|')}'));
    return _format(digest);
  }

  static Future<String> forKey(String key) => forPair(key, key);

  static String _format(List<int> digest) {
    // Take 8 bytes -> big integer string -> pad to 60 digits.
    var value = BigInt.zero;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | BigInt.from(digest[i]);
    }
    var s = value.toString();
    if (s.length > 60) s = s.substring(0, 60);
    s = s.padLeft(60, '0');
    final parts = <String>[];
    for (var i = 0; i < 60; i += 5) {
      parts.add(s.substring(i, i + 5));
    }
    return parts.join(' ');
  }
}

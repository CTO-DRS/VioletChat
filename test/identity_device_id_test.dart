import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/crypto/identity.dart';

/// Regression test for the v0.1.0 splash-hang crash.
///
/// The old deviceId pipeline was:
///   b64(randomBytes(16)).replaceAll(RegExp(r'[^\w]'), '').substring(0, 22)
/// Base64 of 16 bytes is 22 data chars + '==', but [^\w] strips '+' and
/// '/' too — whenever the draw contained exactly one of them, only 21
/// chars remained and substring(0, 22) threw
///   RangeError (end): Invalid value: Not in inclusive range 0..21: 22
/// BEFORE the deviceId was persisted, so every boot re-crashed and the
/// app never left the splash screen (~37% of fresh installs).
void main() {
  test('generateDeviceId always returns exactly 22 word characters', () {
    for (var i = 0; i < 500; i++) {
      final id = IdentityManager.generateDeviceId();
      expect(id.length, 22,
          reason: 'deviceId must be exactly 22 chars (draw $i: "$id")');
      expect(id, matches(RegExp(r'^\w+$')),
          reason: 'deviceId must contain only word chars (draw $i: "$id")');
    }
  });

  test('generateDeviceId yields distinct values across draws', () {
    final seen = <String>{};
    for (var i = 0; i < 50; i++) {
      seen.add(IdentityManager.generateDeviceId());
    }
    // 50 draws from a 62^22 keyspace must not collide.
    expect(seen.length, 50);
  });
}

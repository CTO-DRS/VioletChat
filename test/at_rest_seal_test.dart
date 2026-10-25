import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/core/storage/local_database.dart';

/// audit 2026-10-25 — content-at-rest sealing (LocalDatabase.sealText /
/// openText). The DB itself is not exercised here (sqflite needs a
/// device); these tests pin the crypto contract: round-trip, legacy
/// passthrough, fail-closed corruption, idempotence, fresh nonce.
void main() {
  setUpAll(() {
    // Fake keystore-backed dbKey — sealText/openText only need a key.
    IdentityBridge.register(() async {
      final key = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        key[i] = i;
      }
      return key;
    });
  });

  test('round-trip: Arabic + emoji + newlines', () async {
    const plain = 'مرحبا بالعالم!\nسطر ثانٍ 🙂';
    final sealed = await LocalDatabase.sealText(plain);
    expect(sealed, startsWith('enc1:'));
    // The plaintext must not be readable inside the sealed blob.
    expect(sealed!.contains('مرحبا'), isFalse);
    expect(await LocalDatabase.openText(sealed), plain);
  });

  test('legacy plaintext passes through untouched', () async {
    // Old builds wrote plaintext rows — openText must return them as-is.
    expect(await LocalDatabase.openText('نص قديم عادي'), 'نص قديم عادي');
    expect(await LocalDatabase.openText(null), isNull);
    expect(await LocalDatabase.openText(''), '');
  });

  test('seal is idempotent (already-sealed value unchanged)', () async {
    const plain = 'hello';
    final once = await LocalDatabase.sealText(plain);
    final twice = await LocalDatabase.sealText(once);
    expect(twice, once);
  });

  test('fresh nonce on every seal (non-deterministic)', () async {
    final a = await LocalDatabase.sealText('same text');
    final b = await LocalDatabase.sealText('same text');
    expect(a, isNot(b));
    // Yet both open to the same plaintext.
    expect(await LocalDatabase.openText(a!), 'same text');
    expect(await LocalDatabase.openText(b!), 'same text');
  });

  test('corrupted sealed blob fails CLOSED (null, never ciphertext)',
      () async {
    final sealed = await LocalDatabase.sealText('secret')!;
    // Flip a byte in the ciphertext section.
    final chars = sealed.split('');
    final last = chars.length - 1;
    chars[last] = chars[last] == 'A' ? 'B' : 'A';
    final corrupted = chars.join();
    expect(await LocalDatabase.openText(corrupted), isNull);
  });

  test('marker-shaped garbage fails closed; marker-prefixed prose passes',
      () async {
    // SHAPE-valid blob (12-byte-looking nonce + payload) but bad MAC →
    // fail closed.
    final garbage = 'enc1:${'A' * 16}|${'B' * 24}';
    expect(await LocalDatabase.openText(garbage), isNull);
    // A user literally typed «enc1: …» — not blob-shaped (spaces) →
    // passthrough, never hidden.
    const prose = 'enc1: هذا نص مستخدم عادي ليس blob';
    expect(await LocalDatabase.openText(prose), prose);
  });

  test('empty and null seal passthrough', () async {
    expect(await LocalDatabase.sealText(null), isNull);
    expect(await LocalDatabase.sealText(''), '');
  });
}

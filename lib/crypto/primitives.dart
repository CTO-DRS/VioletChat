import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// ============================================================
/// Cryptographic primitives — single wrapper over the
/// `cryptography` package used by every other crypto module.
///
/// Algorithms (protocol drs-nexora-e2ee-v1):
///  - Key agreement : X25519
///  - Signatures    : Ed25519
///  - KDF           : HKDF-SHA256
///  - AEAD          : AES-256-GCM (12-byte nonce, 16-byte tag)
///  - Hash          : SHA-256
///
/// Wire format for AEAD "merged" blobs: cipherText || mac(16)
/// ============================================================
class Primitives {
  Primitives._();

  static final X25519 x25519 = X25519();
  static final Ed25519 ed25519 = Ed25519();
  static final AesGcm aesGcm = AesGcm.with256bits();
  static final Sha256 sha256 = Sha256();
  static final Hmac sha256Hmac = Hmac.sha256();

  static final Random _secure = Random.secure();

  // ------------------------------------------------------------------
  // Randomness
  // ------------------------------------------------------------------
  static Uint8List randomBytes(int length) => Uint8List.fromList(
      List<int>.generate(length, (_) => _secure.nextInt(256)));

  // ------------------------------------------------------------------
  // Encoding helpers
  // ------------------------------------------------------------------
  static String b64(List<int> bytes) => base64Encode(bytes);
  static Uint8List unb64(String s) => base64Decode(s);
  static String utf8s(List<int> bytes) => utf8.decode(bytes);
  static Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));

  static String b64json(Object? v) =>
      v == null ? '' : b64(utf8.encode(jsonEncode(v)));

  // ------------------------------------------------------------------
  // X25519 key pairs
  // ------------------------------------------------------------------
  static Future<SimpleKeyPair> newX25519() => x25519.newKeyPair();

  static Future<SimpleKeyPair> x25519FromSeed(
      List<int> privateKeyBytes, List<int> publicKeyBytes) async {
    return SimpleKeyPairData(
      privateKeyBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    );
  }

  static Future<String> x25519Pub(SimpleKeyPair kp) async =>
      b64((await kp.extractPublicKey()).bytes);

  /// Raw Diffie-Hellman shared secret (32 bytes).
  static Future<Uint8List> dh(SimpleKeyPair kp, String remotePubB64) async {
    final secret = await x25519.sharedSecretKey(
      keyPair: kp,
      remotePublicKey:
          SimplePublicKey(unb64(remotePubB64), type: KeyPairType.x25519),
    );
    return Uint8List.fromList(await secret.extractBytes());
  }

  // ------------------------------------------------------------------
  // Ed25519 signing key pairs
  // ------------------------------------------------------------------
  static Future<SimpleKeyPair> newEd25519() => ed25519.newKeyPair();

  static Future<SimpleKeyPair> ed25519FromSeed(
      List<int> privateKeyBytes, List<int> publicKeyBytes) async {
    return SimpleKeyPairData(
      privateKeyBytes,
      publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
  }

  static Future<String> ed25519Pub(SimpleKeyPair kp) async =>
      b64((await kp.extractPublicKey()).bytes);

  static Future<String> sign(SimpleKeyPair kp, List<int> message) async {
    final sig = await ed25519.sign(message, keyPair: kp);
    return b64(sig.bytes);
  }

  static Future<bool> verify(
      String publicKeyB64, List<int> message, String signatureB64) async {
    try {
      return await ed25519.verify(
        message,
        signature: Signature(
          unb64(signatureB64),
          publicKey:
              SimplePublicKey(unb64(publicKeyB64), type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // ------------------------------------------------------------------
  // HKDF-SHA256
  // ------------------------------------------------------------------
  static Future<Uint8List> hkdf(
    List<int> ikm, {
    required List<int> salt,
    required List<int> info,
    int length = 32,
  }) async {
    final kdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final key = await kdf.deriveKey(
      secretKey: SecretKeyData(ikm),
      nonce: salt,
      info: info,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// HMAC-SHA256 raw output.
  static Future<Uint8List> hmac(List<int> keyBytes, List<int> message) async {
    final mac = await sha256Hmac.calculateMac(message,
        secretKey: SecretKeyData(keyBytes));
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> hash(List<int> data) async {
    final h = await sha256.hash(data);
    return Uint8List.fromList(h.bytes);
  }

  // ------------------------------------------------------------------
  // AES-256-GCM — merged wire format: cipher || mac(16)
  // ------------------------------------------------------------------
  static Future<Uint8List> seal(List<int> plaintext, Uint8List key,
      {Uint8List? nonce}) async {
    final box = await aesGcm.encrypt(
      plaintext,
      secretKey: SecretKeyData(key),
      nonce: nonce,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  static Future<Uint8List> open(
      Uint8List merged, Uint8List key, Uint8List nonce) async {
    if (merged.length <= 16) {
      throw ArgumentError('ciphertext too short');
    }
    final cipher = Uint8List.sublistView(merged, 0, merged.length - 16);
    final mac = Uint8List.sublistView(merged, merged.length - 16);
    final plain = await aesGcm.decrypt(
      SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
      secretKey: SecretKeyData(key),
    );
    return Uint8List.fromList(plain);
  }

  /// Encrypt with a fresh random nonce and return (nonce, merged).
  static Future<(Uint8List, Uint8List)> sealRandom(
      List<int> plaintext, Uint8List key) async {
    final box = await aesGcm.encrypt(plaintext, secretKey: SecretKeyData(key));
    return (
      Uint8List.fromList(box.nonce),
      Uint8List.fromList([...box.cipherText, ...box.mac.bytes]),
    );
  }
}

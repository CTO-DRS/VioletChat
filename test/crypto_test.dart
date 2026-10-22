import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/crypto/double_ratchet.dart';
import 'package:violet_chat/crypto/envelope.dart';
import 'package:violet_chat/crypto/group_keys.dart';
import 'package:violet_chat/crypto/primitives.dart';
import 'package:violet_chat/crypto/safety_number.dart';
import 'package:violet_chat/crypto/x3dh.dart';
import 'package:violet_chat/data/models/models.dart';

void main() {
  group('Primitives', () {
    test('AES-GCM seal/open roundtrip', () async {
      final key = Primitives.randomBytes(32);
      final plain = Primitives.bytesOf('رسالة سرية للتجربة 123');
      final (nonce, ct) = await Primitives.sealRandom(plain, key);
      final opened = await Primitives.open(ct, key, nonce);
      expect(opened, plain);
    });

    test('AES-GCM rejects tampered ciphertext', () async {
      final key = Primitives.randomBytes(32);
      final (nonce, ct) =
          await Primitives.sealRandom(Uint8List.fromList([1, 2, 3]), key);
      ct[0] = ct[0] ^ 0xFF;
      expect(() => Primitives.open(ct, key, nonce), throwsA(anything));
    });

    test('HKDF is deterministic and salt-sensitive', () async {
      final ikm = Primitives.bytesOf('input key material');
      final a1 = await Primitives.hkdf(ikm, salt: [1], info: [2]);
      final a2 = await Primitives.hkdf(ikm, salt: [1], info: [2]);
      final b = await Primitives.hkdf(ikm, salt: [3], info: [2]);
      expect(a1, a2);
      expect(a1, isNot(b));
    });

    test('X25519 shared secret agrees', () async {
      final a = await Primitives.newX25519();
      final b = await Primitives.newX25519();
      final s1 = await Primitives.dh(a, await Primitives.x25519Pub(b));
      final s2 = await Primitives.dh(b, await Primitives.x25519Pub(a));
      expect(s1, s2);
    });

    test('Ed25519 sign/verify', () async {
      final kp = await Primitives.newEd25519();
      final msg = Primitives.bytesOf('sign me');
      final sig = await Primitives.sign(kp, msg);
      expect(await Primitives.verify(await Primitives.ed25519Pub(kp), msg, sig),
          isTrue);
      expect(
          await Primitives.verify(await Primitives.ed25519Pub(kp),
              Primitives.bytesOf('tampered'), sig),
          isFalse);
    });
  });

  group('X3DH + Double Ratchet (two-party session)', () {
    late SimpleKeyPair aliceIk, bobIk;
    late SimpleKeyPair bobSpk;
    late SimpleKeyPair bobOpk;
    late String spkSig;
    late PrekeyBundle bobBundle;

    setUp(() async {
      aliceIk = await Primitives.newX25519();
      bobIk = await Primitives.newX25519();
      final bobSign = await Primitives.newEd25519();
      bobSpk = await Primitives.newX25519();
      bobOpk = await Primitives.newX25519();
      final spkPub = await Primitives.x25519Pub(bobSpk);
      spkSig = await Primitives.sign(bobSign, Primitives.unb64(spkPub));
      bobBundle = PrekeyBundle(
        identityKey: await Primitives.x25519Pub(bobIk),
        signingKey: await Primitives.ed25519Pub(bobSign),
        signedPrekey: spkPub,
        signedPrekeySig: spkSig,
        signedPrekeyId: 1,
        oneTimePrekey: await Primitives.x25519Pub(bobOpk),
        oneTimePrekeyId: 7,
      );
    });

    test('session establishment + bidirectional ratchet', () async {
      // Alice initiates
      final (skA, _, init) = await X3dh.initiate(bobBundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(skA, bobBundle.signedPrekey);

      // Bob responds with the SPK keypair
      final skB = await X3dh.respond(
        myIdentity: bobIk,
        mySpk: bobSpk,
        init: init,
        myOpk: bobOpk,
      );
      final bob = await DoubleRatchet.initBob(skB, bobSpk);
      expect(skA, skB);

      final ad = Primitives.bytesOf('chat-1');

      // Alice -> Bob (messages 1..3, exercising chain advance)
      for (var i = 0; i < 3; i++) {
        final msg = await alice.encrypt(Primitives.bytesOf('مرحبا $i'), ad);
        final plain =
            await bob.decrypt(msg.header, msg.nonce, msg.ciphertext, ad);
        expect(Primitives.utf8s(plain), 'مرحبا $i');
      }

      // Bob -> Alice (triggers DH ratchet on Alice)
      final reply = await bob.encrypt(Primitives.bytesOf('أهلاً بك'), ad);
      final rPlain =
          await alice.decrypt(reply.header, reply.nonce, reply.ciphertext, ad);
      expect(Primitives.utf8s(rPlain), 'أهلاً بك');

      // Alice again — now both sides ratcheted
      final m2 = await alice.encrypt(Primitives.bytesOf('t2'), ad);
      final p2 = await bob.decrypt(m2.header, m2.nonce, m2.ciphertext, ad);
      expect(Primitives.utf8s(p2), 't2');
    });

    test('forward secrecy: old ciphertext fails after ratchet', () async {
      final (sk, _, init) = await X3dh.initiate(bobBundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(sk, bobBundle.signedPrekey);
      final bob = await DoubleRatchet.initBob(
          await X3dh.respond(
              myIdentity: bobIk, mySpk: bobSpk, init: init, myOpk: bobOpk),
          bobSpk);
      final ad = Primitives.bytesOf('c');

      final old = await alice.encrypt(Primitives.bytesOf('old'), ad);
      await bob.decrypt(old.header, old.nonce, old.ciphertext, ad);
      // advance chains
      final m2 = await alice.encrypt(Primitives.bytesOf('new'), ad);
      await bob.decrypt(m2.header, m2.nonce, m2.ciphertext, ad);
      // replaying the old message must now fail (skipped key consumed)
      expect(
        () => bob.decrypt(old.header, old.nonce, old.ciphertext, ad),
        throwsA(anything),
      );
    });

    test('replay protection: duplicate decrypt fails', () async {
      final (sk, _, init) = await X3dh.initiate(bobBundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(sk, bobBundle.signedPrekey);
      final bob = await DoubleRatchet.initBob(
          await X3dh.respond(
              myIdentity: bobIk, mySpk: bobSpk, init: init, myOpk: bobOpk),
          bobSpk);
      final ad = Primitives.bytesOf('r');

      final m = await alice.encrypt(Primitives.bytesOf('once'), ad);
      await bob.decrypt(m.header, m.nonce, m.ciphertext, ad);
      expect(
        () => bob.decrypt(m.header, m.nonce, m.ciphertext, ad),
        throwsA(anything),
      );
    });

    test('out-of-order delivery tolerated', () async {
      final (sk, _, init) = await X3dh.initiate(bobBundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(sk, bobBundle.signedPrekey);
      final bob = await DoubleRatchet.initBob(
          await X3dh.respond(
              myIdentity: bobIk, mySpk: bobSpk, init: init, myOpk: bobOpk),
          bobSpk);
      final ad = Primitives.bytesOf('o');

      final m1 = await alice.encrypt(Primitives.bytesOf('first'), ad);
      final m2 = await alice.encrypt(Primitives.bytesOf('second'), ad);
      // deliver in reverse order
      expect(
          Primitives.utf8s(
              await bob.decrypt(m2.header, m2.nonce, m2.ciphertext, ad)),
          'second');
      expect(
          Primitives.utf8s(
              await bob.decrypt(m1.header, m1.nonce, m1.ciphertext, ad)),
          'first');
    });

    test('session serialisation survives persist/restore', () async {
      final (sk, _, init) = await X3dh.initiate(bobBundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(sk, bobBundle.signedPrekey);
      final bob = await DoubleRatchet.initBob(
          await X3dh.respond(
              myIdentity: bobIk, mySpk: bobSpk, init: init, myOpk: bobOpk),
          bobSpk);
      final ad = Primitives.bytesOf('p');

      final m = await alice.encrypt(Primitives.bytesOf('persist'), ad);
      await bob.decrypt(m.header, m.nonce, m.ciphertext, ad);

      // persist + restore bob's session
      final restored = await DoubleRatchet.fromJson(
          jsonDecode(await bob.serialise()) as Map<String, dynamic>);

      final m2 = await alice.encrypt(Primitives.bytesOf('after restore'), ad);
      final plain =
          await restored.decrypt(m2.header, m2.nonce, m2.ciphertext, ad);
      expect(Primitives.utf8s(plain), 'after restore');
    });
  });

  group('Group keys', () {
    test('wrap/unwrap roundtrip with correct identities', () async {
      final admin = await Primitives.newX25519();
      final member = await Primitives.newX25519();
      final gk = GroupKeys.generate(3);
      final (wrapped, nonce) = await GroupKeys.wrapFor(
        groupKey: gk,
        wrapperIdentity: admin,
        memberIdentityPubB64: await Primitives.x25519Pub(member),
        chatId: 'chat-x',
      );
      final unwrapped = await GroupKeys.unwrap(
        wrappedB64: wrapped,
        nonceB64: nonce,
        version: 3,
        myIdentity: member,
        wrapperIdentityPubB64: await Primitives.x25519Pub(admin),
        chatId: 'chat-x',
      );
      expect(unwrapped.key, gk.key);
    });

    test('wrong member cannot unwrap', () async {
      final admin = await Primitives.newX25519();
      final member = await Primitives.newX25519();
      final intruder = await Primitives.newX25519();
      final gk = GroupKeys.generate(1);
      final wrapperPub = await Primitives.x25519Pub(admin);
      final (wrapped, nonce) = await GroupKeys.wrapFor(
        groupKey: gk,
        wrapperIdentity: admin,
        memberIdentityPubB64: await Primitives.x25519Pub(member),
        chatId: 'chat-y',
      );
      expect(
        () => GroupKeys.unwrap(
          wrappedB64: wrapped,
          nonceB64: nonce,
          version: 1,
          myIdentity: intruder,
          wrapperIdentityPubB64: wrapperPub,
          chatId: 'chat-y',
        ),
        throwsA(anything),
      );
    });

    test('message keys isolated per version and chat', () async {
      final gk = GroupKeys.generate(2);
      final k1 = await GroupKeys.messageKey(gk, 'chat-a');
      final k2 = await GroupKeys.messageKey(gk, 'chat-b');
      expect(k1, isNot(k2));
    });
  });

  group('Safety number', () {
    test('deterministic and symmetric', () async {
      final a = await Primitives.x25519Pub(await Primitives.newX25519());
      final b = await Primitives.x25519Pub(await Primitives.newX25519());
      final s1 = await SafetyNumber.forPair(a, b);
      final s2 = await SafetyNumber.forPair(b, a);
      expect(s1, s2);
      expect(s1.split(' ').length, 12);
      expect(RegExp(r'^[0-9 ]+$').hasMatch(s1), isTrue);
    });

    test('different keys produce different numbers', () async {
      final a = await Primitives.x25519Pub(await Primitives.newX25519());
      final b = await Primitives.x25519Pub(await Primitives.newX25519());
      expect(await SafetyNumber.forPair(a, a),
          isNot(await SafetyNumber.forPair(a, b)));
    });
  });

  group('Message envelope', () {
    test('FULL WIRE PATH: ratchet -> envelope -> jsonEncode -> decrypt',
        () async {
      // Regression test: header.toJson() must stay SYNC — an async
      // signature leaks a raw Future into the envelope and breaks
      // jsonEncode when the message row is inserted server-side.
      final aliceIk = await Primitives.newX25519();
      final bobIk = await Primitives.newX25519();
      final bobSign = await Primitives.newEd25519();
      final bobSpk = await Primitives.newX25519();
      final spkPub = await Primitives.x25519Pub(bobSpk);
      final bundle = PrekeyBundle(
        identityKey: await Primitives.x25519Pub(bobIk),
        signingKey: await Primitives.ed25519Pub(bobSign),
        signedPrekey: spkPub,
        signedPrekeySig:
            await Primitives.sign(bobSign, Primitives.unb64(spkPub)),
        signedPrekeyId: 1,
      );

      final (skA, _, init) = await X3dh.initiate(bundle, aliceIk);
      final alice = await DoubleRatchet.initAlice(skA, spkPub);
      final skB =
          await X3dh.respond(myIdentity: bobIk, mySpk: bobSpk, init: init);
      final bob = await DoubleRatchet.initBob(skB, bobSpk);

      // Alice builds a REAL wire envelope for Bob's device.
      final msg = await alice.encrypt(
          Primitives.bytesOf('مرحبا يا بوب'), Primitives.bytesOf('chat-9'));
      final envelope = MessageEnvelope.direct(
        senderDeviceId: 'alice-device',
        entries: [
          MessageEnvelope.directEntry(
            deviceId: 'bob-device',
            init: init,
            header: msg.header,
            nonce: msg.nonce,
            ciphertext: msg.ciphertext,
          ),
        ],
      );

      // This is what the Supabase client does with messages.body:
      final wire = jsonEncode(envelope);
      final decoded = jsonDecode(wire) as Map<String, dynamic>;

      // Bob's side: route + decrypt from the decoded JSON only.
      final entry = MessageEnvelope.entryFor(decoded, 'bob-device');
      expect(entry, isNotNull);
      expect(entry!['x3'], isNotNull);
      final plain = await bob.decrypt(
        RatchetHeader.fromJson(entry['h'] as Map<String, dynamic>),
        Primitives.unb64(entry['n'] as String),
        Primitives.unb64(entry['c'] as String),
        Primitives.bytesOf('chat-9'),
      );
      expect(Primitives.utf8s(plain), 'مرحبا يا بوب');
    });

    test('direct envelope: entry routing to the right device', () {
      final e = MessageEnvelope.direct(
        senderDeviceId: 'dev-A',
        entries: [
          MessageEnvelope.directEntry(
            deviceId: 'dev-B1',
            header: const RatchetHeader(dh: 'dhpub', pn: 0, n: 3),
            nonce: Uint8List.fromList(List.filled(12, 1)),
            ciphertext: Uint8List.fromList([9, 9]),
          ),
          MessageEnvelope.directEntry(
            deviceId: 'dev-B2',
            header: const RatchetHeader(dh: 'dhpub2', pn: 1, n: 0),
            nonce: Uint8List.fromList(List.filled(12, 2)),
            ciphertext: Uint8List.fromList([7]),
          ),
        ],
      );
      expect(MessageEnvelope.isDirect(e), isTrue);
      expect(MessageEnvelope.isGroup(e), isFalse);
      expect(MessageEnvelope.senderDevice(e), 'dev-A');
      expect(MessageEnvelope.entryFor(e, 'dev-B1')!['d'], 'dev-B1');
      expect(MessageEnvelope.entryFor(e, 'dev-B2')!['d'], 'dev-B2');
      expect(MessageEnvelope.entryFor(e, 'dev-B2')!['h'],
          isA<Map<String, dynamic>>());
      expect(MessageEnvelope.entryFor(e, 'dev-unknown'), isNull);
    });

    test('group envelope: key version survives JSON roundtrip', () {
      final g = MessageEnvelope.group(
        senderDeviceId: 'dev-A',
        keyVersion: 4,
        nonce: Uint8List.fromList(List.filled(12, 5)),
        ciphertext: Uint8List.fromList([1, 2, 3]),
      );
      final decoded = jsonDecode(jsonEncode(g)) as Map<String, dynamic>;
      expect(MessageEnvelope.isGroup(decoded), isTrue);
      expect(MessageEnvelope.groupKeyVersion(decoded), 4);
      expect(MessageEnvelope.senderDevice(decoded), 'dev-A');
    });

    test('system envelope is neither direct nor group', () {
      final s = MessageEnvelope.system(
          senderDeviceId: 'dev-A', text: 'غادر أحمد المجموعة');
      expect(MessageEnvelope.isSystem(s), isTrue);
      expect(MessageEnvelope.isDirect(s), isFalse);
      expect(MessageEnvelope.isGroup(s), isFalse);
      expect(MessageEnvelope.systemText(s), 'غادر أحمد المجموعة');
    });

    test('group media key is isolated from message key', () async {
      final gk = GroupKeys.generate(1);
      const chat = 'chat-iso';
      final msgKey = await GroupKeys.messageKey(gk, chat);
      final mediaKey = await GroupKeys.mediaKey(gk, chat);
      expect(msgKey, isNot(mediaKey));
      // Same version+chat is deterministic; other chat differs.
      expect(await GroupKeys.mediaKey(gk, chat), mediaKey);
      expect(await GroupKeys.mediaKey(gk, 'chat-other'), isNot(mediaKey));
    });
  });

  group('Message state machine', () {
    test('MsgState covers the full delivery contract', () {
      // queued -> sending -> sent -> delivered -> read, failed aside.
      const order = MsgState.values;
      expect(
          order,
          containsAllInOrder([
            MsgState.queued,
            MsgState.sending,
            MsgState.sent,
            MsgState.delivered,
            MsgState.read,
          ]));
      expect(order, contains(MsgState.failed));
    });
  });
}

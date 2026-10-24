import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/core/storage/key_value_store.dart';
import 'package:violet_chat/services/pin_lock_service.dart';
import 'package:violet_chat/services/scheduled_messages_service.dart';
import 'package:violet_chat/services/translation_service.dart';

void main() {
  group('v0.1.14 — PinLockService', () {
    late PinLockService pin;

    setUp(() {
      pin = PinLockService(MemoryKeyValueStore());
      PinLockService.instance = pin;
    });

    test('not set by default', () async {
      expect(await pin.isPinSet(), isFalse);
      expect(await pin.pinLength(), isNull);
    });

    test('set + verify round-trip, wrong pin rejected', () async {
      await pin.setPin('4821');
      expect(await pin.isPinSet(), isTrue);
      expect(await pin.pinLength(), 4);
      expect(await pin.verifyPin('4821'), isTrue);
      expect(await pin.verifyPin('4822'), isFalse);
      expect(await pin.verifyPin(''), isFalse);
    });

    test('5- and 6-digit pins are stored with their exact length', () async {
      await pin.setPin('918273');
      expect(await pin.pinLength(), 6);
      expect(await pin.verifyPin('918273'), isTrue);
      await pin.setPin('13579');
      expect(await pin.pinLength(), 5);
      expect(await pin.verifyPin('13579'), isTrue);
    });

    test('setPin rejects non-digit / out-of-range input', () async {
      expect(() => pin.setPin('123'), throwsArgumentError);
      expect(() => pin.setPin('1234567'), throwsArgumentError);
      expect(() => pin.setPin('12a4'), throwsArgumentError);
    });

    test('salted hash: same pin twice → different stored hashes', () async {
      final storeA = MemoryKeyValueStore();
      final a = PinLockService(storeA);
      await a.setPin('1111');
      final storeB = MemoryKeyValueStore();
      final b = PinLockService(storeB);
      await b.setPin('1111');
      final ha = await storeA.read('violet.pin.hash.v1');
      final hb = await storeB.read('violet.pin.hash.v1');
      expect(ha, isNotNull);
      expect(hb, isNotNull);
      expect(ha, isNot(hb)); // random salt per set → different digests
      expect(await a.verifyPin('1111'), isTrue);
      expect(await b.verifyPin('1111'), isTrue);
    });

    test('verifyWithThrottle: 5 wrong entries → 30s cool-down', () async {
      await pin.setPin('7777');
      for (var i = 0; i < 5; i++) {
        expect(await pin.verifyWithThrottle('0000'), isFalse);
      }
      expect(pin.lockedOut, isTrue);
      expect(pin.lockoutSecsRemaining, greaterThan(0));
      // While locked out even the CORRECT pin is rejected (brake).
      expect(await pin.verifyWithThrottle('7777'), isFalse);
    });

    test('clearPin removes everything', () async {
      await pin.setPin('2468');
      await pin.clearPin();
      expect(await pin.isPinSet(), isFalse);
      expect(await pin.verifyPin('2468'), isFalse);
    });
  });

  group('v0.1.14 — TranslationService (pure logic)', () {
    test('pickTarget: Arabic → en, Latin → ar', () {
      expect(TranslationService.pickTarget('مرحبا بالعالم'), 'en');
      expect(TranslationService.pickTarget('Hello world'), 'ar');
      // Mixed, mostly Arabic → en.
      expect(TranslationService.pickTarget('هذا test صغير جدا'), 'en');
      // No letters at all → default ar.
      expect(TranslationService.pickTarget('12345 !!!'), 'ar');
    });

    test('parseGtx concatenates segments and reads detected source', () {
      final decoded = jsonDecode(
          '[[["مرحبا","hello",null,null,10],[" يا عالم"," world",null,null,5]],null,"en"]')
          as List;
      final r = TranslationService.parseGtx(decoded, 'ar');
      expect(r.text, 'مرحبا يا عالم');
      expect(r.source, 'en');
      expect(r.target, 'ar');
    });

    test('parseGtx survives a malformed body', () {
      final r = TranslationService.parseGtx(<dynamic>[], 'ar');
      expect(r.text, '');
      expect(r.source, 'auto');
    });
  });

  group('v0.1.14 — ScheduledMessage', () {
    test('JSON round-trip keeps all fields (UTC-normalised)', () {
      final m = ScheduledMessage(
        id: 'abc',
        chatId: 'chat-1',
        text: 'سلام مؤجل',
        sendAt: DateTime.utc(2026, 10, 24, 15, 30),
        createdAt: DateTime.utc(2026, 10, 23, 10, 0),
        replyTo: 'msg-9',
        replyPreview: 'الأصل',
      );
      final back = ScheduledMessage.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.id, 'abc');
      expect(back.chatId, 'chat-1');
      expect(back.text, 'سلام مؤجل');
      expect(back.sendAt, m.sendAt);
      expect(back.createdAt, m.createdAt);
      expect(back.replyTo, 'msg-9');
      expect(back.replyPreview, 'الأصل');
    });

    test('isDueAt honours the boundary', () {
      final m = ScheduledMessage(
        id: 'x',
        chatId: 'c',
        text: 'hi',
        sendAt: DateTime.utc(2026, 10, 24, 12, 0),
        createdAt: DateTime.utc(2026, 10, 24, 11, 0),
      );
      expect(m.isDueAt(DateTime.utc(2026, 10, 24, 11, 59)), isFalse);
      expect(m.isDueAt(DateTime.utc(2026, 10, 24, 12, 0)), isTrue);
      expect(m.isDueAt(DateTime.utc(2026, 10, 24, 12, 1)), isTrue);
    });

    test('service queue: add → load → forChat sorted → cancel → persist',
        () async {
      final store = MemoryKeyValueStore();
      final svc = ScheduledMessagesService(store);
      // load() with nothing stored is a no-op (fireDue no-ops: no sender).
      await svc.load();
      expect(svc.all, isEmpty);

      await svc.add(
          chatId: 'c1',
          text: 'أولاً',
          sendAt: DateTime.utc(2026, 11, 1, 9, 0));
      await svc.add(
          chatId: 'c2',
          text: 'لمحادثة أخرى',
          sendAt: DateTime.utc(2026, 11, 1, 8, 0));
      await svc.add(
          chatId: 'c1',
          text: 'ثانياً',
          sendAt: DateTime.utc(2026, 11, 1, 7, 0));

      // Chat-filtered, ascending by send time.
      final c1 = svc.forChat('c1');
      expect(c1.map((m) => m.text).toList(), ['ثانياً', 'أولاً']);
      expect(svc.forChat('c2').single.text, 'لمحادثة أخرى');

      // Cancel removes exactly one.
      await svc.cancel(c1.first.id);
      expect(svc.forChat('c1').single.text, 'أولاً');

      // Persistence survives a fresh service on the same store.
      final svc2 = ScheduledMessagesService(store);
      await svc2.load();
      expect(svc2.forChat('c1').single.text, 'أولاً');
      expect(svc2.forChat('c2'), isEmpty);
    });

    test('wipe clears both memory and store (sign-out path)', () async {
      final store = MemoryKeyValueStore();
      final svc = ScheduledMessagesService(store);
      await svc.load();
      await svc.add(
          chatId: 'c',
          text: 's',
          sendAt: DateTime.utc(2026, 11, 1));
      expect(store.read('violet.scheduled.v1'), completes);
      await svc.wipe();
      expect(svc.all, isEmpty);
      expect(await store.read('violet.scheduled.v1'), isNull);
    });
  });
}

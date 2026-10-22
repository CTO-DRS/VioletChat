import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/core/utils/disappearing_policy.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/services/chat_export_service.dart';
import 'package:violet_chat/widgets/swipe_to_reply.dart';

Message _msg({
  String id = 'm1',
  String text = 'مرحبا',
  bool deletedForAll = false,
  String? editedAt,
  String? expiresAt,
  bool starred = false,
  String senderId = 'peer',
  MediaInfo? media,
  String createdAt = '2026-10-08T09:00:00.000Z',
}) =>
    Message(
      id: id,
      chatId: 'chat1',
      senderId: senderId,
      senderDeviceId: 'dev',
      clientMsgId: id,
      kind: media == null ? 'text' : 'media',
      text: text,
      media: media,
      isDeletedForAll: deletedForAll,
      editedAt: editedAt,
      expiresAt: expiresAt,
      starred: starred,
      createdAt: createdAt,
      serverAt: createdAt,
    );

void main() {
  group('DisappearingPolicy — v0.1.0', () {
    test('null/unparseable expiry never expires', () {
      final now = DateTime.utc(2026, 10, 8, 12);
      expect(DisappearingPolicy.isExpired(null, now), isFalse);
      expect(DisappearingPolicy.isExpired('', now), isFalse);
      expect(DisappearingPolicy.isExpired('not-a-date', now), isFalse);
    });

    test('past expiry is expired, future is not', () {
      final now = DateTime.utc(2026, 10, 8, 12);
      expect(
          DisappearingPolicy.isExpired(
              '2026-10-08T11:59:59.000Z', now), // 1s before
          isTrue);
      expect(
          DisappearingPolicy.isExpired('2026-10-08T12:00:01.000Z', now),
          isFalse);
    });

    test('exact boundary counts as expired (<=)', () {
      final now = DateTime.utc(2026, 10, 8, 12);
      expect(DisappearingPolicy.isExpired('2026-10-08T12:00:00.000Z', now),
          isTrue);
    });

    test('labels cover OFF + canonical choices + fallback', () {
      expect(DisappearingPolicy.label(null), 'إيقاف');
      expect(DisappearingPolicy.label(0), 'إيقاف');
      expect(DisappearingPolicy.label(86400), '24 ساعة');
      expect(DisappearingPolicy.label(604800), '7 أيام');
      expect(DisappearingPolicy.label(7776000), '90 يوماً');
      expect(DisappearingPolicy.label(7200), '2 ساعة');
    });

    test('canonical choices are all valid', () {
      for (final t in DisappearingPolicy.ttlChoices) {
        expect(DisappearingPolicy.isKnownChoice(t), isTrue);
        expect(t >= 60, isTrue, reason: 'server rejects ttl < 60');
      }
      expect(DisappearingPolicy.isKnownChoice(42), isFalse);
    });
  });

  group('ChatExportService.buildTranscript — v0.1.0', () {
    test('header carries title + count + warning', () {
      final out = ChatExportService.buildTranscript(
        title: 'فريق التطوير',
        messages: [_msg()],
        nameOf: (_) => 'أنا',
        now: DateTime.utc(2026, 10, 8, 12),
      );
      expect(out, contains('فريق التطوير'));
      expect(out, contains('عدد الرسائل: 1'));
      expect(out, contains('تصدير'));
    });

    test('sender names resolve through nameOf', () {
      final out = ChatExportService.buildTranscript(
        title: 't',
        messages: [
          _msg(senderId: 'me', text: 'مني'),
          _msg(id: 'm2', senderId: 'peer', text: 'من الطرف'),
        ],
        nameOf: (id) => id == 'me' ? 'أنا' : 'سارة',
      );
      expect(out, contains('أنا: مني'));
      expect(out, contains('سارة: من الطرف'));
    });

    test('deleted-for-all renders a tombstone, media renders placeholder',
        () {
      final out = ChatExportService.buildTranscript(
        title: 't',
        messages: [
          _msg(deletedForAll: true),
          _msg(
              id: 'm2',
              media: const MediaInfo(
                  type: 'image',
                  path: 'p',
                  size: 1,
                  mime: 'image/jpeg',
                  fileKey: 'k',
                  fileNonce: 'n')),
        ],
        nameOf: (_) => 'x',
      );
      expect(out, contains('تم حذف هذه الرسالة'));
      expect(out, contains('📷 صورة'));
    });

    test('edited messages are marked', () {
      final out = ChatExportService.buildTranscript(
        title: 't',
        messages: [_msg(editedAt: '2026-10-08T10:00:00.000Z')],
        nameOf: (_) => 'x',
      );
      expect(out, contains('(معدّلة)'));
    });
  });

  group('SwipeToReply gesture math — v0.1.0', () {
    test('shapeDrag clamps magnitude, preserves direction', () {
      expect(SwipeToReply.shapeDrag(300), 96);
      expect(SwipeToReply.shapeDrag(-300), -96);
      expect(SwipeToReply.shapeDrag(30), 30);
      expect(SwipeToReply.shapeDrag(0), 0);
      expect(SwipeToReply.shapeDrag(double.nan), 0);
    });

    test('threshold crosses in BOTH directions (RTL-safe)', () {
      expect(SwipeToReply.crossesThreshold(-72, 72), isTrue);
      expect(SwipeToReply.crossesThreshold(80, 72), isTrue);
      expect(SwipeToReply.crossesThreshold(71.9, 72), isFalse);
    });
  });

  group('Models — v0.1.0 fields', () {
    test('Message.copyWith flips starred without touching other fields',
        () {
      final m = _msg(text: 'hi', starred: false);
      final starred = m.copyWith(starred: true);
      expect(starred.starred, isTrue);
      expect(starred.text, 'hi');
      expect(starred.expiresAt, m.expiresAt);
      final un = starred.copyWith(starred: false);
      expect(un.starred, isFalse);
    });

    test('Chat.copyWithFlags sentinel semantics for disappearTtlSeconds',
        () {
      const c = Chat(
          id: 'c',
          type: 'direct',
          createdAt: '',
          disappearTtlSeconds: 86400);
      // untouched:
      expect(c.copyWithFlags().disappearTtlSeconds, 86400);
      // explicit clear:
      expect(
          c.copyWithFlags(disappearTtlSeconds: null).disappearTtlSeconds,
          isNull);
      // explicit set:
      expect(
          c.copyWithFlags(disappearTtlSeconds: 604800).disappearTtlSeconds,
          604800);
    });
  });
}

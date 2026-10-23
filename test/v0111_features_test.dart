// v0.1.11 feature tests — تعديل الاستطلاعات + ردود الحالات + حالات الفيديو.
//
// منطق نقي (بلا منصة/شبكة):
//  - PollForm: قواعد التحقق المشتركة بين الإنشاء والتعديل
//  - تعديل الاستطلاع: pollId ثابت → الأصوات القائمة تبقى مترابطة؛
//    تقليص الخيارات يجعل فهارسها الخارج النطاق تُهمَل دفاعياً
//  - storyReply: حمصة الرد داخل التشفير (text + storyRef) ذهاباً-وإياباً
//  - Message: storyRef عبر copyWith
//  - MediaInfo فيديو: نوع وميتاداتا تنتقل عبر JSON (مسار حالات الفيديو)
//  - StoryContent بالفيديو: ليست فارغة (تصير قابلة للعرض)
import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/core/constants/app_constants.dart';
import 'package:violet_chat/core/utils/poll_tally.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/features/messages/poll_widgets.dart'
    show PollForm;
import 'package:violet_chat/services/message_crypto_service.dart';
import 'package:violet_chat/services/story_service.dart';

Message _vote({
  required String id,
  required String sender,
  String? replyTo,
  String? pollRef = 'p1',
  required int option,
  DateTime? at,
  bool deleted = false,
}) =>
    Message(
      id: id,
      chatId: 'chat-1',
      senderId: sender,
      senderDeviceId: 'dev',
      clientMsgId: id,
      kind: AppConstants.kindPollVote,
      pollVote: option,
      pollRef: pollRef,
      replyTo: replyTo,
      isDeletedForAll: deleted,
      createdAt: (at ?? DateTime.now().toUtc()).toIso8601String(),
      serverAt: '',
    );

Message _pollRow(PollInfo poll) => Message(
      id: 'row-1',
      chatId: 'chat-1',
      senderId: 'owner',
      senderDeviceId: 'd',
      clientMsgId: 'p1',
      kind: AppConstants.kindPoll,
      poll: poll,
      createdAt: '2026-10-24T00:00:00Z',
      serverAt: '',
    );

void main() {
  // ------------------------------------------------------------------
  // PollForm — قواعد الإنشاء والتعديل المشتركة
  // ------------------------------------------------------------------
  group('PollForm.validate', () {
    test('سؤال فارغ مرفوض', () {
      expect(PollForm.validate('   ', ['a', 'b']), isNotNull);
      expect(PollForm.validate('', ['a', 'b']), isNotNull);
    });

    test('أقل من خيارين مرفوض (والفارغ يُحتسب مفقوداً)', () {
      expect(PollForm.validate('q', []), isNotNull);
      expect(PollForm.validate('q', ['فقط واحد']), isNotNull);
      expect(PollForm.validate('q', ['', '', '  ']), isNotNull);
    });

    test('صالح: سؤال وخياران (الفراغات تُقص)', () {
      expect(PollForm.validate('  سؤال  ', [' a ', 'b']), isNull);
    });
  });

  // ------------------------------------------------------------------
  // تعديل الاستطلاع — pollId ثابت والأصوات تبقى
  // ------------------------------------------------------------------
  group('Poll edit semantics', () {
    const original =
        PollInfo(pollId: 'p1', question: 'القديم؟', options: ['أ', 'ب', 'ج']);
    final row = _pollRow(original);

    test('التعديل يحافظ على pollId — إعادة البناء كما في editPoll', () {
      // نفس التحول النقي في ChatController.editPoll
      final edited = PollInfo(
        pollId: original.pollId, // ← لا يتغير أبداً
        question: 'الجديد؟',
        options: ['أ', 'ب', 'ج', 'د'],
        multi: original.multi,
      );
      // ذهاب-وإياب عبر الحمولة المشفرة (كما يخزنها الخادم/الذاكرة)
      final back = PollInfo.fromJson(edited.toJson());
      expect(back!.pollId, 'p1');
      expect(back.question, 'الجديد؟');
      expect(back.options, ['أ', 'ب', 'ج', 'د']);
    });

    test('الأصوات القائمة تُعدّ بعد التعديل (نفس pollRef)', () {
      final edited = PollInfo(
          pollId: original.pollId,
          question: 'الجديد؟',
          options: ['أ', 'ب', 'ج', 'د']);
      final editedRow = _pollRow(edited);
      final t = PollTally.tally(editedRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 0),
        _vote(id: 'v2', sender: 'u2', pollRef: 'p1', option: 2),
      ]);
      expect(PollTally.totalVoters(t), 2);
      expect(t[0], ['u1']);
      expect(t[2], ['u2']);
    });

    test('تقليص الخيارات: الفهارس الخارج النطاق تُهمَل دفاعياً', () {
      final shrunk = PollInfo(
          pollId: original.pollId, question: 'مختصر؟', options: ['أ', 'ب']);
      final shrunkRow = _pollRow(shrunk);
      final t = PollTally.tally(shrunkRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 0),
        _vote(id: 'v2', sender: 'u2', replyTo: 'row-1', option: 2), // خارج
      ]);
      expect(PollTally.totalVoters(t), 1);
      expect(t[0], ['u1']);
      expect(t[2], isNull);
    });

    test('صفر أصوات هو شرط التعديل — الحارس يقرأ من الفرز نفسه', () {
      final t = PollTally.tally(row, const []);
      expect(PollTally.totalVoters(t) == 0, isTrue); // يُسمح بالتعديل
      final t2 = PollTally.tally(row, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 1),
      ]);
      expect(PollTally.totalVoters(t2) == 0, isFalse); // يُمنع التعديل
    });
  });

  // ------------------------------------------------------------------
  // storyReply — رد الحالة داخل التشفير
  // ------------------------------------------------------------------
  group('StoryReply payload', () {
    test('ذهاب وإياب: النص ومرجع الحالة داخل التشفير', () {
      const inner = InnerPayload(
        kind: 'storyReply',
        text: 'حالة رائعة!',
        storyRef: 'story-uuid-1',
      );
      final back = InnerPayload.fromJson(inner.toJson());
      expect(back.kind, 'storyReply');
      expect(back.text, 'حالة رائعة!');
      expect(back.storyRef, 'story-uuid-1');
      expect(back.pollRef, isNull);
      expect(back.poll, isNull);
    });

    test('Message يحمل storyRef عبر copyWith', () {
      final m = Message(
        id: 'r1',
        chatId: 'c',
        senderId: 'u1',
        senderDeviceId: 'd',
        clientMsgId: 'cm1',
        kind: AppConstants.kindStoryReply,
        text: 'ردّي',
        storyRef: 'story-9',
        createdAt: '2026-10-24T00:00:00Z',
        serverAt: '',
      );
      final starred = m.copyWith(starred: true);
      expect(starred.storyRef, 'story-9');
      expect(starred.kind, AppConstants.kindStoryReply);
      expect(starred.starred, isTrue);
    });

    test('الرد ليس رصيصاً — لا يُفرز ولا يُخفى', () {
      // الفرز يتجاهل أي رسالة ليست pollVote؛ الرد يبقى في السجل عادياً
      const poll = PollInfo(pollId: 'p1', question: 'q', options: ['a', 'b']);
      final reply = Message(
        id: 'r9',
        chatId: 'chat-1',
        senderId: 'u1',
        senderDeviceId: 'd',
        clientMsgId: 'cm9',
        kind: AppConstants.kindStoryReply,
        text: 'نص الرد',
        storyRef: 'story-1',
        createdAt: '2026-10-24T00:00:00Z',
        serverAt: '',
      );
      final t = PollTally.tally(_pollRow(poll), [reply]);
      expect(PollTally.totalVoters(t), 0);
    });
  });

  // ------------------------------------------------------------------
  // حالات الفيديو — MediaInfo فيديو داخل الحمولة المشفرة
  // ------------------------------------------------------------------
  group('Video story media', () {
    test('MediaInfo فيديو: ذهاب وإياب عبر JSON', () {
      const info = MediaInfo(
        type: 'video',
        path: 'media/stories/u1/x.enc',
        size: 1234567,
        mime: 'video/mp4',
        name: 'clip.mp4',
        width: 1080,
        height: 1920,
        durationMs: 42000,
        fileKey: 'K=',
        fileNonce: 'N=',
      );
      final back = MediaInfo.fromJson(info.toJson());
      expect(back!.type, 'video');
      expect(back.mime, 'video/mp4');
      expect(back.durationMs, 42000);
      expect(back.width, 1080);
      expect(back.height, 1920);
      expect(back.fileKey, 'K=');
    });

    test('StoryContent بالفيديو ليست فارغة — تُعرض في العارض', () {
      const c = StoryContent(
        media: MediaInfo(
          type: 'video',
          path: 'p',
          size: 1,
          mime: 'video/mp4',
          fileKey: 'k',
          fileNonce: 'n',
        ),
      );
      expect(c.isEmpty, isFalse);
      expect(c.media!.type, 'video');
    });

    test('حمصة الحالة تستوعب الفيديو والنص معاً (تعليق)', () {
      final body = {
        'kind': 'story',
        'text': 'تعليق على الفيديو',
        'media': const MediaInfo(
          type: 'video',
          path: 'p',
          size: 1,
          mime: 'video/mp4',
          fileKey: 'k',
          fileNonce: 'n',
        ).toJson(),
      };
      final media = MediaInfo.fromJson(body['media'] as Map<String, dynamic>);
      expect(media!.type, 'video');
      expect(body['text'], 'تعليق على الفيديو');
    });
  });
}

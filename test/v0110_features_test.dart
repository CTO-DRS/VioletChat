// v0.1.10 feature tests — الاستطلاعات المشفرة + حالات الأصدقاء.
//
// منطق نقي + تشفير حقيقي (بلا منصة/شبكة):
//  - PollInfo / InnerPayload: حمولة استطلاع ذهاباً-وإياباً داخل الطبقة المشفرة
//  - PollTally: الفرز طرف-لطرف (صوت واحد لكل مصوّت، آخر صوت يفوز، تجاهل التالف)
//  - Message: حقول poll/pollVote + copyWith يحفظها
//  - StoryItem: انتهاء الصلاحية
//  - تشفير الحالة الحقيقي: مفتاح عشوائي → ختم AES-GCM → تغليف X25519+HKDF
//    لجهازين مستقبلين → فك التغليف → فك الختم (نفس مسار StoryService).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/core/constants/app_constants.dart';
import 'package:violet_chat/core/utils/poll_tally.dart';
import 'package:violet_chat/crypto/group_keys.dart';
import 'package:violet_chat/crypto/primitives.dart';
import 'package:violet_chat/data/models/models.dart';
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

void main() {
  // ------------------------------------------------------------------
  // PollInfo — الترميز داخل الحمولة المشفرة
  // ------------------------------------------------------------------
  group('PollInfo', () {
    test('ذهاب وإياب عبر JSON', () {
      const p = PollInfo(
          pollId: 'poll-1', question: 'متى نطلق؟', options: ['الجمعة', 'السبت']);
      final back = PollInfo.fromJson(p.toJson());
      expect(back!.pollId, 'poll-1');
      expect(back.question, 'متى نطلق؟');
      expect(back.options, ['الجمعة', 'السبت']);
      expect(back.multi, isFalse);
    });

    test('دفاعي: null والتالف يرجعان null بلا انهيار', () {
      expect(PollInfo.fromJson(null), isNull);
      expect(PollInfo.fromJson(const {}), isNotNull); // حقول افتراضية فارغة
      // خيارات غير قائمة → TypeError → catch → null
      expect(PollInfo.fromJson({'options': 'not-a-list'}), isNull);
    });

    test('isValidOption يحرس الحدود', () {
      const p = PollInfo(pollId: 'x', question: 'q', options: ['a', 'b']);
      expect(p.isValidOption(0), isTrue);
      expect(p.isValidOption(1), isTrue);
      expect(p.isValidOption(2), isFalse);
      expect(p.isValidOption(-1), isFalse);
    });
  });

  // ------------------------------------------------------------------
  // InnerPayload — الاستطلاع والصوت داخل المظروف المشفر
  // ------------------------------------------------------------------
  group('InnerPayload poll/vote', () {
    test('استطلاع: ذهاب وإياب', () {
      const inner = InnerPayload(
        kind: 'poll',
        poll: PollInfo(pollId: 'p1', question: 'q', options: ['a', 'b']),
      );
      final back = InnerPayload.fromJson(inner.toJson());
      expect(back.kind, 'poll');
      expect(back.poll!.pollId, 'p1');
      expect(back.poll!.options.length, 2);
      expect(back.pollVote, isNull);
    });

    test('صوت: الفهرس والربط المشفر ينتقلان صحيحين', () {
      const inner = InnerPayload(
          kind: 'pollVote', pollVote: 1, pollRef: 'p1');
      final back = InnerPayload.fromJson(inner.toJson());
      expect(back.kind, 'pollVote');
      expect(back.pollVote, 1);
      expect(back.pollRef, 'p1');
      expect(back.poll, isNull);
    });
  });

  // ------------------------------------------------------------------
  // Message — الحقول الجديدة وcopyWith
  // ------------------------------------------------------------------
  group('Message poll fields', () {
    test('poll وpollVote يبقيان عبر copyWith', () {
      const poll = PollInfo(pollId: 'p1', question: 'q', options: ['a', 'b']);
      final m = Message(
        id: 'r1',
        chatId: 'c',
        senderId: 'u1',
        senderDeviceId: 'd',
        clientMsgId: 'p1',
        kind: AppConstants.kindPoll,
        poll: poll,
        createdAt: '2026-10-24T00:00:00Z',
        serverAt: '',
      );
      final edited = m.copyWith(starred: true);
      expect(edited.poll!.pollId, 'p1');
      expect(edited.starred, isTrue);

      final v = _vote(
          id: 'v1', sender: 'u2', replyTo: 'r1', option: 1);
      final vs = v.copyWith(localState: MsgState.sent);
      expect(vs.pollVote, 1);
    });
  });

  // ------------------------------------------------------------------
  // PollTally — الفرز الطرف-لطرف
  // ------------------------------------------------------------------
  group('PollTally', () {
    const poll = PollInfo(pollId: 'p1', question: 'q', options: ['a', 'b', 'c']);
    final pollRow = Message(
      id: 'row-1', // id صف الخادم
      chatId: 'chat-1',
      senderId: 'owner',
      senderDeviceId: 'd',
      clientMsgId: 'p1',
      kind: AppConstants.kindPoll,
      poll: poll,
      createdAt: '2026-10-24T00:00:00Z',
      serverAt: '',
    );

    test('سلة فارغة = صفر أصوات', () {
      final t = PollTally.tally(pollRow, const []);
      expect(PollTally.totalVoters(t), 0);
      expect(PollTally.percent(t, 0), 0);
      expect(PollTally.myVote(t, 'me'), isNull);
    });

    test('فرز أساسي — صوتان لخيارين', () {
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 0),
        _vote(id: 'v2', sender: 'u2', replyTo: 'row-1', option: 1),
      ]);
      expect(PollTally.totalVoters(t), 2);
      expect(t[0], ['u1']);
      expect(t[1], ['u2']);
      expect(PollTally.percent(t, 0), 50);
    });

    test('آخر صوت يفوز — تغيير الرأي', () {
      final base = DateTime.utc(2026, 10, 24, 12);
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 0,
            at: base),
        _vote(id: 'v2', sender: 'u1', replyTo: 'row-1', option: 2,
            at: base.add(const Duration(minutes: 2))),
      ]);
      expect(PollTally.totalVoters(t), 1);
      expect(t[2], ['u1']);
      expect(t[0], isNull);
      expect(PollTally.myVote(t, 'u1'), 2);
    });

    test('صوت محذوف-للجميع يُهمل', () {
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 0,
            deleted: true),
      ]);
      expect(PollTally.totalVoters(t), 0);
    });

    test('فهرس خارج النطاق يُهمل دفاعياً', () {
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', replyTo: 'row-1', option: 9),
        _vote(id: 'v2', sender: 'u2', replyTo: 'row-1', option: 1),
      ]);
      expect(PollTally.totalVoters(t), 1);
      expect(t[1], ['u2']);
    });

    test('بالوت لاستطلاع آخر يُهمل (لا pollRef ولا reply_to)', () {
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', pollRef: 'other',
            replyTo: 'other-row', option: 0),
      ]);
      expect(PollTally.totalVoters(t), 0);
    });

    test('الربط المشفر pollRef وحده يكفي (بلا reply_to)', () {
      // مسار الـplaceholder: صوت على استطلاعي قبل تأكد صف الخادم
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', pollRef: 'p1', replyTo: null,
            option: 1),
      ]);
      expect(PollTally.totalVoters(t), 1);
      expect(t[1], ['u1']);
    });

    test('reply_to وحده يكفي (عملاء قديمة/بديلة)', () {
      final t = PollTally.tally(pollRow, [
        _vote(id: 'v1', sender: 'u1', pollRef: null, replyTo: 'row-1',
            option: 2),
      ]);
      expect(PollTally.totalVoters(t), 1);
      expect(t[2], ['u1']);
    });
  });

  // ------------------------------------------------------------------
  // StoryItem — انتهاء الصلاحية
  // ------------------------------------------------------------------
  group('StoryItem', () {
    test('منتهي وقائم', () {
      final now = DateTime.now().toUtc();
      final live = StoryItem(
          id: 's1',
          authorId: 'a',
          createdAt: now.toIso8601String(),
          expiresAt: now.add(const Duration(hours: 1)).toIso8601String());
      final dead = StoryItem(
          id: 's2',
          authorId: 'a',
          createdAt: now.subtract(const Duration(hours: 25)).toIso8601String(),
          expiresAt: now.subtract(const Duration(hours: 1)).toIso8601String());
      expect(live.isExpired, isFalse);
      expect(dead.isExpired, isTrue);
    });
  });

  // ------------------------------------------------------------------
  // تشفير الحالة الحقيقي — نفس مسار StoryService (بلا شبكة)
  // ------------------------------------------------------------------
  group('Story crypto path', () {
    test('مفتاح الحالة: ختم → تغليف لجهازين → فك → فتح', () async {
      // مفتاح الحالة العشوائي (كما في StoryService.publish)
      final storyKey = Primitives.randomBytes(32);

      // ختم المتن (AES-256-GCM nonce عشوائي)
      final body = jsonEncode({'kind': 'story', 'text': 'مرحباً'});
      final (nonce, ct) =
          await Primitives.sealRandom(Primitives.bytesOf(body), storyKey);

      // مؤلف يغلف المفتاح لجهازَي مستقبلين عبر نفس مخطط مفاتيح المجموعات
      final author = await Primitives.newX25519();
      final friend1Dev = await Primitives.newX25519();
      final friend2Dev = await Primitives.newX25519();
      final friend1Pub = await Primitives.x25519Pub(friend1Dev);
      final friend2Pub = await Primitives.x25519Pub(friend2Dev);

      final wrap1 = await GroupKeys.wrapFor(
        groupKey: GroupKeyEnvelope(0, storyKey),
        wrapperIdentity: author,
        memberIdentityPubB64: friend1Pub,
        chatId: 'violet-stories',
      );
      final wrap2 = await GroupKeys.wrapFor(
        groupKey: GroupKeyEnvelope(0, storyKey),
        wrapperIdentity: author,
        memberIdentityPubB64: friend2Pub,
        chatId: 'violet-stories',
      );

      // المستقبلان يفكان التغليف بمفاتيحهما (محاولة هويات المؤلف كما في
      // StoryService._resolveStoryKey)
      final authorPub = await Primitives.x25519Pub(author);
      final key1 = await GroupKeys.unwrap(
        wrappedB64: wrap1.$1,
        nonceB64: wrap1.$2,
        version: 0,
        myIdentity: friend1Dev,
        wrapperIdentityPubB64: authorPub,
        chatId: 'violet-stories',
      );
      final key2 = await GroupKeys.unwrap(
        wrappedB64: wrap2.$1,
        nonceB64: wrap2.$2,
        version: 0,
        myIdentity: friend2Dev,
        wrapperIdentityPubB64: authorPub,
        chatId: 'violet-stories',
      );

      // المفتاحان يطابقان الأصل ويفتحان المتن
      expect(Primitives.b64(key1.key), Primitives.b64(storyKey));
      expect(Primitives.b64(key2.key), Primitives.b64(storyKey));
      final plain1 = await Primitives.open(ct, key1.key, nonce);
      expect(Primitives.utf8s(plain1), body);
    });

    test('هوية خاطئة للفك تفشل (عزل الأجهزة)', () async {
      final storyKey = Primitives.randomBytes(32);
      final author = await Primitives.newX25519();
      final stranger = await Primitives.newX25519();
      final friend = await Primitives.newX25519();
      final friendPub = await Primitives.x25519Pub(friend);
      final wrap = await GroupKeys.wrapFor(
        groupKey: GroupKeyEnvelope(0, storyKey),
        wrapperIdentity: author,
        memberIdentityPubB64: friendPub,
        chatId: 'violet-stories',
      );
      final strangerTries = GroupKeys.unwrap(
        wrappedB64: wrap.$1,
        nonceB64: wrap.$2,
        version: 0,
        myIdentity: stranger,
        wrapperIdentityPubB64: await Primitives.x25519Pub(author),
        chatId: 'violet-stories',
      );
      await expectLater(strangerTries, throwsA(anything));
    });
  });
}

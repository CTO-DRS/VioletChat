// v0.1.13 feature tests — الرؤية الواحدة + البحث داخل المحادثة + سرعات الصوت.
//
// منطق نقي (بلا منصة/شبكة):
//  - MediaInfo.once: ذهاباً-وإياباً داخل الحمولة المشفرة + رسائل تراث
//    بلا مفتاح 'once' تُقرأ false + wire يبقى بلا مفتاح عندما false
//  - MediaUploadResult.toMediaInfo(once:): تمرير العلم من UI للتشفير
//  - InnerPayload: مسار wire الحقيقي (media.once داخل التشفير)
//  - ViewOnce: تنسيق مفتاح kv (vo:<id>)
//  - messageHaystack/messageMatchesQuery: تطبيع عربي متسامح على
//    (النص + اسم الملف + سؤال وخيارات الاستطلاع + وسم الموقع + البطاقة)
//  - nextPlaybackSpeed/playbackSpeedLabel: سلم السرعات 1×→1.5×→2×
//  - kindPreview: معاينة وسائط الرؤية الواحدة لا تتسرب لمحتواها
import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/core/constants/app_constants.dart';
import 'package:violet_chat/core/utils/message_search.dart';
import 'package:violet_chat/core/utils/playback_speed.dart';
import 'package:violet_chat/core/utils/view_once.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/features/messages/location_contact_widgets.dart'
    show kindPreview;
import 'package:violet_chat/services/media_service.dart';
import 'package:violet_chat/services/message_crypto_service.dart';

Message _msg({
  required String kind,
  String? text,
  Map<String, dynamic>? mediaJson,
  PollInfo? poll,
  LocationInfo? location,
  ContactInfo? contact,
}) =>
    Message(
      id: 'row-1',
      chatId: 'chat-1',
      senderId: 'u1',
      senderDeviceId: 'd1',
      clientMsgId: 'c1',
      kind: kind,
      text: text,
      media:
          mediaJson == null ? null : MediaInfo.fromJson(mediaJson),
      poll: poll,
      location: location,
      contact: contact,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      serverAt: '',
    );

Map<String, dynamic> _mediaJson(
    {String type = 'image', String? name, bool once = false}) =>
    {
      'type': type,
      'path': 'chats/c1/media/blob.enc',
      'size': 1024,
      'mime': type == 'image' ? 'image/jpeg' : 'video/mp4',
      if (name != null) 'name': name,
      'fkey': 'a2V5',
      'fnonce': 'bm9uY2U=',
      if (once) 'once': true,
    };

void main() {
  // ================================================================
  // MediaInfo.once — العلم يسافر داخل النص المشفر فقط
  // ================================================================
  group('MediaInfo.once', () {
    test('roundtrip: once=true يُخزَّن ويُقرأ', () {
      final m = MediaInfo.fromJson(_mediaJson(once: true))!;
      expect(m.once, isTrue);
      final j = m.toJson();
      expect(j['once'], isTrue);
      final back = MediaInfo.fromJson(j);
      expect(back!.once, isTrue);
      expect(back.type, 'image');
      expect(back.fileKey, 'a2V5');
    });

    test('رسالة تراث بلا مفتاح once تُقرأ false (توافق أمامي)', () {
      final legacy = MediaInfo.fromJson(_mediaJson());
      expect(legacy!.once, isFalse);
    });

    test('once=false لا يكتب مفتاح once على الwire إطلاقاً', () {
      const m = MediaInfo(
        type: 'audio',
        path: 'p',
        size: 1,
        mime: 'audio/mp4',
        fileKey: 'k',
        fileNonce: 'n',
      );
      expect(m.once, isFalse);
      expect(m.toJson().containsKey('once'), isFalse);
    });
  });

  // ================================================================
  // MediaUploadResult.toMediaInfo(once:) — تمرير العلم
  // ================================================================
  group('toMediaInfo once', () {
    test('once:true يصل إلى MediaInfo', () {
      const r = MediaUploadResult(
        type: 'video',
        path: 'p',
        size: 10,
        mime: 'video/mp4',
        fileKey: 'k',
        fileNonce: 'n',
        durationMs: 1500,
      );
      expect(r.toMediaInfo(once: true).once, isTrue);
      expect(r.toMediaInfo().once, isFalse);
      expect(r.toMediaInfo(once: true).durationMs, 1500);
    });
  });

  // ================================================================
  // InnerPayload — media.once داخل التشفير (الخادم لا يرى شيئاً)
  // ================================================================
  group('InnerPayload view-once wire', () {
    test('media.once يبقى عبر toJson/fromJson', () {
      final media = MediaInfo.fromJson(_mediaJson(once: true));
      final p = InnerPayload(kind: 'media', media: media, text: 'انظر');
      final back = InnerPayload.fromJson(p.toJson());
      expect(back.kind, 'media');
      expect(back.media!.once, isTrue);
      expect(back.text, 'انظر');
      // مفتاح wire هو 'media' — نفس ما يكتبه sync_engine.enqueueMedia.
      final wire = p.toJson();
      expect(wire['media'], isA<Map<String, dynamic>>());
      expect((wire['media'] as Map<String, dynamic>)['once'], isTrue);
    });
  });

  // ================================================================
  // ViewOnce — مفاتيح kv
  // ================================================================
  group('ViewOnce keys', () {
    test('key format vo:<id>', () {
      expect(ViewOnce.key('abc-123'), 'vo:abc-123');
      expect(ViewOnce.key(''), 'vo:');
    });
  });

  // ================================================================
  // message_search — البحث داخل المحادثة (تطبيع عربي متسامح)
  // ================================================================
  group('messageMatchesQuery', () {
    test('نص عادي مع تطبيع الهمزات', () {
      final m = _msg(kind: 'text', text: 'أحمد قال السلام عليكم');
      expect(messageMatchesQuery(m, 'احمد'), isTrue);
      expect(messageMatchesQuery(m, 'أحمد'), isTrue);
      expect(messageMatchesQuery(m, 'السلام'), isTrue);
      expect(messageMatchesQuery(m, 'عليكم'), isTrue);
      // المطابقة حرفية بعد التطبيع: «السلام» لا تحتوي «اسلام»
      // (اللام تتقدم على السين) — سلوك موثق لا يُخفى.
      expect(messageMatchesQuery(m, 'اسلام'), isFalse);
      expect(messageMatchesQuery(m, 'مساء'), isFalse);
    });

    test('تشكيل لا يمنع المطابقة', () {
      final m = _msg(kind: 'text', text: 'مُراجعة الدَّرس');
      expect(messageMatchesQuery(m, 'مراجعة'), isTrue);
      expect(messageMatchesQuery(m, 'الدرس'), isTrue);
    });

    test('اسم ملف الوسائط يدخل في البحث', () {
      final m = _msg(
          kind: 'media', mediaJson: _mediaJson(name: 'تقرير-المشروع.pdf'));
      expect(messageMatchesQuery(m, 'تقرير'), isTrue);
      expect(messageMatchesQuery(m, 'مشروع'), isTrue);
    });

    test('سؤال الاستطلاع وخياراته يدخلون في البحث', () {
      final m = _msg(
        kind: AppConstants.kindPoll,
        poll: const PollInfo(
            pollId: 'poll-1',
            question: 'ما أفضل وقت للاجتماع؟',
            options: ['صباحاً', 'مساءً']),
      );
      expect(messageMatchesQuery(m, 'اجتماع'), isTrue);
      expect(messageMatchesQuery(m, 'صباحا'), isTrue);
      expect(messageMatchesQuery(m, 'مساء'), isTrue);
      expect(messageMatchesQuery(m, 'ليل'), isFalse);
    });

    test('وسم الموقع واسم بطاقة الاتصال يدخلون في البحث', () {
      final loc = _msg(
        kind: AppConstants.kindLocation,
        location: const LocationInfo(lat: 24.7, lng: 46.6, label: 'المكتب'),
      );
      expect(messageMatchesQuery(loc, 'مكتب'), isTrue);

      final card = _msg(
        kind: AppConstants.kindContact,
        contact: const ContactInfo(
            username: 'salem', displayName: 'سالم العُمري'),
      );
      expect(messageMatchesQuery(card, 'سالم'), isTrue);
      expect(messageMatchesQuery(card, 'salem'), isTrue);
      expect(messageMatchesQuery(card, 'عمري'), isTrue);
    });

    test('استعلام فارغ يطابق كل شيء', () {
      final m = _msg(kind: 'text', text: 'أي شيء');
      expect(messageMatchesQuery(m, ''), isTrue);
      expect(messageMatchesQuery(m, '   '), isTrue);
    });

    test('haystack لا يرمي أبداً على حقول ناقصة', () {
      final bare = _msg(
          kind: 'media', mediaJson: _mediaJson(name: 'blob.pdf'));
      expect(messageHaystack(bare), isNotEmpty);
      expect(messageMatchesQuery(bare, 'blob'), isTrue);
      // بلا اسم ملف: التطبيع لا يرمي — يرجع haystack نصه الفارغ.
      final nameless = _msg(kind: 'media', mediaJson: _mediaJson());
      expect(messageMatchesQuery(nameless, 'blob'), isFalse);
    });
  });

  // ================================================================
  // playback_speed — سلم السرعات
  // ================================================================
  group('playback speed', () {
    test('الدورة 1× → 1.5× → 2× → 1×', () {
      expect(nextPlaybackSpeed(1.0), 1.5);
      expect(nextPlaybackSpeed(1.5), 2.0);
      expect(nextPlaybackSpeed(2.0), 1.0);
    });

    test('قيمة مجهولة تعيد الدورة من 1×', () {
      expect(nextPlaybackSpeed(3.75), 1.0);
      expect(playbackSpeeds.contains(nextPlaybackSpeed(9.0)), isTrue);
    });

    test('تسميات مختصرة بلا .0', () {
      expect(playbackSpeedLabel(1.0), '1×');
      expect(playbackSpeedLabel(1.5), '1.5×');
      expect(playbackSpeedLabel(2.0), '2×');
    });
  });

  // ================================================================
  // kindPreview — معاينة الرؤية الواحدة تُعلن النوع ولا تكشف شيئاً
  // ================================================================
  group('kindPreview for once-media', () {
    test('صورة/صوت/فيديو بمشاهدة واحدة = نفس معاينة الوسائط', () {
      final img = _msg(kind: 'media', mediaJson: _mediaJson());
      final onceImg =
          _msg(kind: 'media', mediaJson: _mediaJson(once: true));
      expect(kindPreview(onceImg), kindPreview(img));

      final vid = _msg(
          kind: 'media',
          mediaJson: _mediaJson(type: 'video', name: 'clip.mp4'));
      final onceVid = _msg(
          kind: 'media',
          mediaJson: _mediaJson(type: 'video', name: 'clip.mp4', once: true));
      expect(kindPreview(onceVid), kindPreview(vid));
    });
  });
}

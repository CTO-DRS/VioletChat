// v0.1.12 feature tests — الموقع المشفر + بطاقات جهات الاتصال + تنسيق النص.
//
// منطق نقي (بلا منصة/شبكة):
//  - LocationInfo: ذهاباً-وإياباً + دفاع ضد الإحداثيات الملوثة
//  - ContactInfo: ذهاباً-وإياباً + اسم فارغ يسقط لاسم المستخدم
//  - InnerPayload: مسار wire الحقيقي (loc/card داخل التشفير)
//  - Message: location/contact عبر copyWith + placeholder
//  - parseMessageSegments: كل قواعد التنسيق (غامق/مائل/شطب/كود/
//    مختلط/غير مغلق/فارغ/كود يحمي علاماته/ثابت التجميع)
//  - kindPreview: معاينة موحدة لكل الأنواع
//  - replyPreviewOf: شريط الرد الصادق لكل الأنواع
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/core/constants/app_constants.dart';
import 'package:violet_chat/core/utils/text_format.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/features/messages/location_contact_widgets.dart'
    show kindPreview;
import 'package:violet_chat/services/message_crypto_service.dart';
import 'package:violet_chat/state/chat_controller.dart';

Message _msg({
  required String kind,
  String? text,
  LocationInfo? location,
  ContactInfo? contact,
  String? replyPreview,
  Map<String, dynamic>? mediaJson,
}) =>
    Message(
      id: 'row-1',
      chatId: 'chat-1',
      senderId: 'u1',
      senderDeviceId: 'd1',
      clientMsgId: 'c1',
      kind: kind,
      text: text,
      media: mediaJson == null
          ? null
          : MediaInfo.fromJson(mediaJson),
      location: location,
      contact: contact,
      replyPreview: replyPreview,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      serverAt: '',
    );

void main() {
  // ================================================================
  // LocationInfo
  // ================================================================
  group('LocationInfo', () {
    test('roundtrip يحفظ الإحداثيات والوسم', () {
      const loc = LocationInfo(lat: 24.7136, lng: 46.6753, label: 'المنزل');
      final j = loc.toJson();
      final back = LocationInfo.fromJson(j);
      expect(back, isNotNull);
      expect(back!.lat, closeTo(24.7136, 1e-9));
      expect(back.lng, closeTo(46.6753, 1e-9));
      expect(back.label, 'المنزل');
    });

    test('وسم فارغ يُسقط من toJson', () {
      const loc = LocationInfo(lat: 1, lng: 2, label: '   ');
      expect(loc.toJson().containsKey('label'), isFalse);
    });

    test('دفاع: خط عرض خارج النطاق يفسد الحمولة', () {
      expect(
          LocationInfo.fromJson(
              {'lat': 91.0, 'lng': 45.0}), isNull);
      expect(
          LocationInfo.fromJson(
              {'lat': 10.0, 'lng': -181.0}), isNull);
      expect(LocationInfo.fromJson({'lat': 10.0}), isNull); // lng مفقود
      expect(LocationInfo.fromJson(null), isNull);
      expect(
          LocationInfo.fromJson(
              {'lat': 'not-a-number', 'lng': 2}), isNull);
    });

    test('geoUri يضم الوسم مرمزاً والحلقة الويب صحيحة', () {
      const loc = LocationInfo(lat: 24.7, lng: 46.6, label: 'المكتب');
      expect(loc.geoUri(), startsWith('geo:24.7,46.6?q=24.7,46.6'));
      expect(loc.geoUri(), contains(Uri.encodeComponent('المكتب')));
      expect(loc.webMapUri(),
          'https://www.google.com/maps/search/?api=1&query=24.7,46.6');
    });

    test('coordsText بدقة 5 أرقام', () {
      const loc = LocationInfo(lat: 24.71361234, lng: 46.67539999);
      expect(loc.coordsText(), '24.71361, 46.67540');
    });
  });

  // ================================================================
  // ContactInfo
  // ================================================================
  group('ContactInfo', () {
    test('roundtrip يحفظ الاسم واسم المستخدم', () {
      const card = ContactInfo(username: 'ahmad', displayName: 'أحمد');
      final back = ContactInfo.fromJson(card.toJson());
      expect(back!.username, 'ahmad');
      expect(back.displayName, 'أحمد');
    });

    test('اسم مستخدم فارغ يفسد الحمولة دفاعياً', () {
      expect(ContactInfo.fromJson({'username': '  ', 'name': 'x'}), isNull);
      expect(ContactInfo.fromJson({'name': 'بدون مستخدم'}), isNull);
      expect(ContactInfo.fromJson(null), isNull);
    });

    test('اسم العرض الفارغ يسقط إلى اسم المستخدم', () {
      final back =
          ContactInfo.fromJson({'username': 'sara', 'name': '   '});
      expect(back!.displayName, 'sara');
    });

    test('initials عربي: كلمتان → أول حرف من كل كلمة', () {
      const card = ContactInfo(username: 'u', displayName: 'أحمد محمد');
      expect(card.initials(), 'أم');
    });

    test('initials كلمة واحدة → حتى حرفين', () {
      const card = ContactInfo(username: 'u', displayName: 'سارة');
      expect(card.initials().length, 2);
    });
  });

  // ================================================================
  // InnerPayload — مسار wire المشفر
  // ================================================================
  group('InnerPayload location/contact', () {
    test('location: ذهاباً-وإياباً عبر toJson/fromJson', () {
      const loc = LocationInfo(lat: 21.4858, lng: 39.1925, label: 'مكة');
      const p = InnerPayload(kind: AppConstants.kindLocation, location: loc);
      final back = InnerPayload.fromJson(p.toJson());
      expect(back.kind, AppConstants.kindLocation);
      expect(back.location!.lat, closeTo(21.4858, 1e-9));
      expect(back.location!.label, 'مكة');
      // مفتاح wire هو 'loc' — نفس ما يكتبه sync_engine.
      expect(p.toJson()['loc'], isA<Map<String, dynamic>>());
    });

    test('contact: ذهاباً-وإياباً عبر toJson/fromJson', () {
      const card = ContactInfo(username: 'sara', displayName: 'سارة');
      const p = InnerPayload(kind: AppConstants.kindContact, contact: card);
      final back = InnerPayload.fromJson(p.toJson());
      expect(back.kind, AppConstants.kindContact);
      expect(back.contact!.username, 'sara');
      expect(p.toJson()['card'], isA<Map<String, dynamic>>());
    });

    test('حمولة تالفة داخل التشفير → حقول null بلا انفجار', () {
      final bad = InnerPayload.fromJson({
        'kind': AppConstants.kindLocation,
        'loc': {'lat': 999, 'lng': 999},
      });
      expect(bad.location, isNull);
      final badCard = InnerPayload.fromJson({
        'kind': AppConstants.kindContact,
        'card': {'username': ''},
      });
      expect(badCard.contact, isNull);
    });
  });

  // ================================================================
  // Message — الحقول الجديدة
  // ================================================================
  group('Message location/contact fields', () {
    test('placeholder يحمل الموقع والبطاقة', () {
      const loc = LocationInfo(lat: 1, lng: 2);
      final m = Message.placeholder(
        clientMsgId: 'cm-1',
        chatId: 'chat-1',
        senderId: 'u1',
        senderDeviceId: 'd1',
        text: null,
        media: null,
        kind: AppConstants.kindLocation,
        location: loc,
      );
      expect(m.location!.lat, 1);
      expect(m.kind, AppConstants.kindLocation);
    });

    test('copyWith يمرر الموقع والبطاقة', () {
      const loc = LocationInfo(lat: 1, lng: 2);
      const card = ContactInfo(username: 'x', displayName: 'X');
      final base = _msg(kind: 'text', text: 'hi');
      final withLoc = base.copyWith(location: loc);
      final withCard = base.copyWith(contact: card);
      expect(withLoc.location!.lng, 2);
      expect(withCard.contact!.username, 'x');
      // copyWith يحافظ على القائمة (poll ?? this.poll النمط نفسه).
      expect(withLoc.copyWith().location!.lat, 1);
    });
  });

  // ================================================================
  // تنسيق النص — parseMessageSegments
  // ================================================================
  group('text_format', () {
    test('نص عادي بلا علامات يبقى قصاصة واحدة', () {
      final segs = parseMessageSegments('مرحبا بالعالم');
      expect(segs.length, 1);
      expect(segs.single.text, 'مرحبا بالعالم');
      expect(segs.single.style, isNull);
    });

    test('غامق **مُغلَق**', () {
      final segs = parseMessageSegments('a **غامق** b');
      expect(segs.map((s) => s.style).toList(),
          [null, 'bold', null]);
      expect(segs[1].text, 'غامق');
      expect(segs.map((s) => s.text).toList(), ['a ', 'غامق', ' b']);
    });

    test('العلامات المُستهلكة تتحول نمطاً لا نصاً (ليس ثابت تجميع)', () {
      // بالتصميم: قصاصة موسومة تحمل النص الداخلي فقط — العلامات
      // نفسها تختفي من النص وتظهر كنمط. التحقق: القصاصات النهائية
      // لا تخسر أي حرف غير علامة.
      final segs = parseMessageSegments('عربي **bold** نهاية');
      expect(segs.map((s) => s.text).toList(),
          ['عربي ', 'bold', ' نهاية']);
      expect(segs[1].style, 'bold');
    });

    test('مائل وشطب وكود', () {
      expect(parseMessageSegments('*م*').single.style, 'italic');
      expect(parseMessageSegments('~~ح~~').single.style, 'strike');
      expect(parseMessageSegments('`x=1`').single.style, 'code');
      expect(parseMessageSegments('`x=1`').single.text, 'x=1');
    });

    test('مختلط في جملة واحدة', () {
      final segs = parseMessageSegments('**مهم** و *ثانوي* و `كود`');
      expect(segs.map((s) => s.style),
          ['bold', null, 'italic', null, 'code']);
    });

    test('علامة غير مغلقة تبقى حرفية', () {
      final segs = parseMessageSegments('**لم يُغلق أبداً');
      expect(segs.length, 1);
      expect(segs.single.style, isNull);
      expect(segs.single.text, '**لم يُغلق أبداً');
    });

    test('علامات فارغة تبقى حرفية', () {
      expect(parseMessageSegments('****').single.style, isNull);
      expect(parseMessageSegments('``').single.style, isNull);
    });

    test('الكود يحمي علاماته الداخلية', () {
      final segs = parseMessageSegments('`**ليس غامقاً**`');
      expect(segs.length, 1);
      expect(segs.single.style, 'code');
      expect(segs.single.text, '**ليس غامقاً**');
    });

    test('أولوية الغامق على المائل (***ت*** → غامق «*ت» + بقايا حرفية)', () {
      // سلوك flat موثق: زوج ** الأول يبدأ عند 0 وينتهي عند أول '**'
      // بعده (الموضع 4) — الداخل «*ت» والنجمة الأخيرة تبقى حرفية.
      const src = '***ت***';
      final segs = parseMessageSegments(src);
      expect(segs.length, 2);
      expect(segs[0].style, 'bold');
      expect(segs[0].text, '*ت');
      expect(segs[1].style, isNull);
      expect(segs[1].text, '*');
    });

    test('جملة عربية كاملة مع كل الصيغ — تسلسل دقيق', () {
      const src = 'سلام **عليكم** يا *أصدقائي* ~~القدامى~~ `violet chat` ❤️';
      final segs = parseMessageSegments(src);
      expect(
          segs.map((s) => s.style).toList(),
          [null, 'bold', null, 'italic', null, 'strike', null,
              'code', null]);
      expect(segs[1].text, 'عليكم');
      expect(segs[3].text, 'أصدقائي');
      expect(segs[5].text, 'القدامى');
      expect(segs[7].text, 'violet chat');
      expect(segs[8].text, ' ❤️');
    });

    test('hasMessageFormatting', () {
      expect(hasMessageFormatting('**ب**'), isTrue);
      expect(hasMessageFormatting('نص عادي'), isFalse);
      expect(hasMessageFormatting('** غير مغلق'), isFalse);
    });

    test('بناء TextSpan: نص عادي يرجع span واحد بسيط', () {
      final span = buildMessageSpan('مرحبا',
          base: const TextStyle(fontSize: 14),
          codeStyle: const CodeSpanStyle(
              background: Color(0x11000000), foreground: Colors.grey));
      expect(span.children, isNull); // بلا أطفال — نص واحد
      expect(span.text, 'مرحبا');
    });
  });

  // ================================================================
  // kindPreview — المعاينة الموحدة
  // ================================================================
  group('kindPreview', () {
    test('location → «📍 موقع» حتى مع وسم', () {
      expect(
          kindPreview(_msg(
              kind: AppConstants.kindLocation,
              text: 'وسم',
              location: const LocationInfo(lat: 1, lng: 2))),
          '📍 موقع');
    });

    test('contact → الاسم المعروض', () {
      expect(
          kindPreview(_msg(
              kind: AppConstants.kindContact,
              text: 'سارة',
              contact: const ContactInfo(
                  username: 'sara', displayName: 'سارة'))),
          '👤 سارة');
    });

    test('poll → «📊 استطلاع رأي»', () {
      expect(kindPreview(_msg(kind: AppConstants.kindPoll, text: 'سؤال')),
          '📊 استطلاع رأي');
    });

    test('media بلا تسمية → حسب النوع، ومع تسمية → التسمية', () {
      expect(
          kindPreview(_msg(
              kind: 'media',
              mediaJson: {'type': 'image', 'path': 'x', 'size': 1,
                  'mime': 'image/png', 'fkey': 'k', 'fnonce': 'n'})),
          '📷 صورة');
      expect(
          kindPreview(_msg(
              kind: 'media',
              text: 'التسمية',
              mediaJson: {'type': 'image', 'path': 'x', 'size': 1,
                  'mime': 'image/png', 'fkey': 'k', 'fnonce': 'n'})),
          'التسمية');
    });

    test('storyReply → «↩ النص»', () {
      expect(
          kindPreview(_msg(
              kind: AppConstants.kindStoryReply, text: 'جميلة!')),
          '↩ جميلة!');
    });

    test('نص عادي → نفس النص، والفارغ → «رسالة»', () {
      expect(kindPreview(_msg(kind: 'text', text: 'أهلاً')), 'أهلاً');
      expect(kindPreview(_msg(kind: 'text')), 'رسالة');
    });
  });

  // ================================================================
  // replyPreviewOf — شريط الرد الصادق
  // ================================================================
  group('ChatController.replyPreviewOf', () {
    test('location يعرض «📍 موقع» لا «📎 وسائط»', () {
      final m = _msg(
          kind: AppConstants.kindLocation,
          location: const LocationInfo(lat: 1, lng: 2));
      expect(ChatController.replyPreviewOf(m), '📍 موقع');
    });

    test('contact يعرض الاسم', () {
      final m = _msg(
          kind: AppConstants.kindContact,
          text: 'أحمد',
          contact: const ContactInfo(username: 'a', displayName: 'أحمد'));
      expect(ChatController.replyPreviewOf(m), '👤 أحمد');
    });

    test('نص عادي يعرض النص نفسه', () {
      expect(ChatController.replyPreviewOf(_msg(kind: 'text', text: 'مرح')),
          'مرح');
    });
  });
}

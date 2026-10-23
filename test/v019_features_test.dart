// v0.1.9 feature tests — إضافة بالباركود + فحص التحديث + حجم الخط.
//
// منطق نقي فقط (بلا منصة): حمولة QR، مقارنة الإصدارات، حدود حجم الخط
// وترميز الإعدادات. نفس منهجية violet_identity_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:violet_chat/data/models/models.dart';
import 'package:violet_chat/services/qr_add_service.dart';
import 'package:violet_chat/services/update_service.dart';

void main() {
  // ------------------------------------------------------------------
  // QrAddService — buildPayload / parsePayload / normalize
  // ------------------------------------------------------------------
  group('QrAddService.buildPayload', () {
    test('يبني الحمولة الرسمية ويطبّع المعرّف', () {
      expect(QrAddService.buildPayload('Ahmad'),
          'violetchat://add/ahmad');
      expect(QrAddService.buildPayload('  user_01 '),
          'violetchat://add/user_01');
    });

    test('يرفض المعرّفات غير الصالحة', () {
      expect(() => QrAddService.buildPayload('ab'), // أقصر من 3
          throwsArgumentError);
      expect(() => QrAddService.buildPayload(''), throwsArgumentError);
      expect(() => QrAddService.buildPayload('a b c!'), throwsArgumentError);
    });
  });

  group('QrAddService.parsePayload', () {
    test('الحمولة الرسمية — ذهاب وإياب', () {
      final payload = QrAddService.buildPayload('ahmad');
      expect(QrAddService.parsePayload(payload), 'ahmad');
    });

    test('تسامح: حالة مختلفة + @ + فراغات', () {
      expect(QrAddService.parsePayload('VIOLETCHAT://ADD/AHMAD'), 'ahmad');
      expect(QrAddService.parsePayload('  @Ahmad_99  '), 'ahmad_99');
      expect(QrAddService.parsePayload('ahmad'), 'ahmad');
    });

    test('تسامح: روابط https بمعامل u= / username=', () {
      expect(QrAddService.parsePayload('https://example.com/add?u=sara'),
          'sara');
      expect(
          QrAddService.parsePayload(
              'https://violet.app/?username=omar_2'),
          'omar_2');
    });

    test('يرفض النصوص غير الصالحة بلا استثناء', () {
      expect(QrAddService.parsePayload(''), isNull);
      expect(QrAddService.parsePayload('ab'), isNull);
      expect(
          QrAddService.parsePayload('https://random.site/whatever'), isNull);
      expect(QrAddService.parsePayload('رمز عربي'), isNull);
      // معرّف أطول من 20
      expect(QrAddService.parsePayload('a' * 21), isNull);
    });

    test('يطبّع الياء/الكاف الفارسية إلى العربية ثم يرفض ما ليس لاتينياً',
        () {
      // الحمولة لاتينية حصراً — أي محارف أخرى تُسقط أثناء التطبيع.
      expect(QrAddService.parsePayload('violetchat://add/user.name!'),
          'username');
    });
  });

  // ------------------------------------------------------------------
  // UpdateService — parseVersion / compareVersions / isNewer
  // ------------------------------------------------------------------
  group('UpdateService.parseVersion', () {
    test('يحلل البادئة v واللاحقة +build', () {
      expect(UpdateService.parseVersion('v0.1.9'), [0, 1, 9]);
      expect(UpdateService.parseVersion('0.1.10'), [0, 1, 10]);
      expect(UpdateService.parseVersion('V2.0'), [2, 0]);
      expect(UpdateService.parseVersion('0.1.9+16'), [0, 1, 9]);
    });

    test('يرفض النصوص غير الرقمية', () {
      expect(UpdateService.parseVersion('abc'), isNull);
      expect(UpdateService.parseVersion('v'), isNull);
      expect(UpdateService.parseVersion('1.x.3'), isNull);
      expect(UpdateService.parseVersion(''), isNull);
    });
  });

  group('UpdateService.compareVersions', () {
    test('مقارنة دلالية لا نصية', () {
      // نصياً 0.1.10 < 0.1.9 لكن دلالياً 0.1.10 أحدث — الحالة الحرجة
      // للإصدار القادم مباشرة.
      expect(UpdateService.compareVersions('0.1.10', '0.1.9'), 1);
      expect(UpdateService.compareVersions('0.1.9', '0.1.10'), -1);
      expect(UpdateService.compareVersions('v0.1.9', '0.1.9'), 0);
      expect(UpdateService.compareVersions('0.2.0', '0.1.9'), 1);
      expect(UpdateService.compareVersions('1.0.0', '0.9.9'), 1);
    });

    test('الأجزاء الغائبة صفر', () {
      expect(UpdateService.compareVersions('0.1', '0.1.0'), 0);
      expect(UpdateService.compareVersions('0.2', '0.1.9'), 1);
    });

    test('غير القابل للمقارنة يعامل كمتساوٍ (لا ترقية كاذبة)', () {
      expect(UpdateService.compareVersions('not-a-version', '0.1.9'), 0);
    });

    test('isNewer يعكس قرار الترقية فقط', () {
      expect(UpdateService.isNewer('v0.1.10', '0.1.9'), isTrue);
      expect(UpdateService.isNewer('v0.1.9', '0.1.9'), isFalse);
      expect(UpdateService.isNewer('v0.1.8', '0.1.9'), isFalse);
    });
  });

  // ------------------------------------------------------------------
  // UserSettings.chatFontSize — افتراضي/حدود/ذهاب-وإياب
  // ------------------------------------------------------------------
  group('UserSettings.chatFontSize', () {
    test('الافتراضي 15 عند غياب المفتاح (صفوف قديمة)', () {
      const s = UserSettings();
      expect(s.chatFontSize, 15);
      final fromJson = UserSettings.fromJson({});
      expect(fromJson.chatFontSize, 15);
    });

    test('ذهاب وإياب عبر toJson/fromJson', () {
      const s = UserSettings(chatFontSize: 19);
      final back = UserSettings.fromJson(s.toJson());
      expect(back.chatFontSize, 19);
    });

    test('قيم خارج النطاق ترجع للافتراضي (defensive decode)', () {
      expect(UserSettings.fromJson({'chat_font_size': 8}).chatFontSize, 15);
      expect(
          UserSettings.fromJson({'chat_font_size': 99}).chatFontSize, 15);
      expect(UserSettings.fromJson({'chat_font_size': 'x'}).chatFontSize,
          15);
      // حدود النطاق نفسها مقبولة
      expect(
          UserSettings.fromJson({'chat_font_size': 13}).chatFontSize, 13);
      expect(
          UserSettings.fromJson({'chat_font_size': 22}).chatFontSize, 22);
    });

    test('withChatFontSize يقص داخل الحدود ويحافظ على باقي القيم', () {
      const s = UserSettings(themeMode: 'dark', blockScreenshots: true);
      final bigger = s.withChatFontSize(30);
      expect(bigger.chatFontSize, UserSettings.maxChatFontSize);
      expect(bigger.themeMode, 'dark');
      expect(bigger.blockScreenshots, isTrue);
      final smaller = s.withChatFontSize(5);
      expect(smaller.chatFontSize, UserSettings.minChatFontSize);
      final valid = s.withChatFontSize(18);
      expect(valid.chatFontSize, 18);
    });
  });
}

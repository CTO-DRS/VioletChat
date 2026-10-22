import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:violet_chat/services/violet_auth_service.dart';
import 'package:violet_chat/services/violet_profile_service.dart';

/// اختبارات طبقة هوية Violet Chat — المنطق النقي الحقيقي:
/// التحقق من الحقول، خرائط الأخطاء عربي/إنجليزي، حمولة ملف
/// Firestore، وسلوك وضع legacy عند غياب Firebase.
/// (استدعاءات الخدمة الحية مقصورة على CI بعد تفعيل Console —
/// موثق في docs/FIREBASE_SETUP.md وBUILD_RESULTS.md.)
void main() {
  group('VioletValidators.email — التحقق من صيغة البريد', () {
    test('يقبل بريداً صحيحاً', () {
      expect(VioletValidators.email('user@example.com'), isNull);
      expect(VioletValidators.email('  user.tag+vx@sub.domain.co  '), isNull);
    });

    test('يرفض الفراغ والصيغ السيئة', () {
      expect(VioletValidators.email(''), isNotNull);
      expect(VioletValidators.email(null), isNotNull);
      expect(VioletValidators.email('not-an-email'), isNotNull);
      expect(VioletValidators.email('a@b'), isNotNull); // لا TLD
      expect(VioletValidators.email('a b@c.com'), isNotNull);
      expect(VioletValidators.email('@no-local.com'), isNotNull);
    });
  });

  group('VioletValidators.password — كلمات المرور القصيرة', () {
    test('يرفض الأقل من 8 أحرف', () {
      expect(VioletValidators.password(''), isNotNull);
      expect(VioletValidators.password('a1b2c3'), isNotNull); // 6
      expect(VioletValidators.password('a1b2c3d'), isNotNull); // 7
    });

    test('يقبل 8+ ويقبل العربية والرموز', () {
      expect(VioletValidators.password('a1b2c3d4'), isNull);
      expect(VioletValidators.password('كلمة-مرور-قوية-99'), isNull);
      expect(VioletValidators.password('p@ssw0rd!!'), isNull);
    });
  });

  group('VioletValidators.displayName', () {
    test('يرفض القصير جداً والطويل جداً والفراغ', () {
      expect(VioletValidators.displayName(''), isNotNull);
      expect(VioletValidators.displayName('  أ  '), isNotNull); // حرف واحد
      expect(VioletValidators.displayName('a' * 41), isNotNull);
    });

    test('يقبل اسماً طبيعياً بعد التقليم', () {
      expect(VioletValidators.displayName('  أحمد  '), isNull);
      expect(VioletValidators.displayName('Sara'), isNull);
    });
  });

  group('VioletValidators.deriveUsername — اشتقاق اسم المراسلة', () {
    test('يحول الاسم العربي إلى أساس لاتيني عبر البريد', () {
      final u = VioletValidators.deriveUsername('أحمد', 'ahmed@test.com');
      expect(RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(u), isTrue);
    });

    test('يقتطع الأسماء اللاتينية الطويلة', () {
      final u = VioletValidators.deriveUsername('AlexanderHamilton', 'x@y.co');
      expect(u, 'alexanderhamilton'.substring(0, 20));
    });
  });

  group('VioletAuthErrors — رسائل واضحة بالعربية والإنجليزية', () {
    test('خرائط الأخطاء المعروفة (عربي)', () {
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('email-already-in-use', '')),
        contains('مسجّل مسبقاً'),
      );
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('too-many-requests', '')),
        contains('محاولات كثيرة'),
      );
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('network-request-failed', '')),
        contains('تحقق من الإنترنت'),
      );
      // CONFIGURATION_NOT_FOUND — الحالة الحقيقية قبل تفعيل Console
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('CONFIGURATION_NOT_FOUND', '')),
        contains('غير مهيأة'),
      );
    });

    test('النسخة الإنجليزية متاحة لنفس الأكواد', () {
      expect(
        VioletAuthErrors.messageEn(
            const VioletAuthFailure('email-already-in-use', '')),
        contains('already registered'),
      );
      expect(
        VioletAuthErrors.messageEn(
            const VioletAuthFailure('weak-password', '')),
        contains('Weak password'),
      );
    });

    test('FirebaseAuthException الحقيقي يُفهرس بكوده', () {
      final e = FirebaseAuthException(code: 'invalid-email');
      expect(VioletAuthErrors.messageAr(e), contains('صيغة البريد'));
    });

    test('الفشل المجهول يرجع رسالة عامة آمنة', () {
      expect(VioletAuthErrors.messageAr(Exception('xyz-unknown-42')),
          contains('تعذر إكمال'));
    });

    test('وضع عدم التوفر يوجه للمسار القائم', () {
      final msg = VioletAuthErrors.messageAr(const VioletUnavailableException());
      expect(msg, contains('حساب المراسلة القائم'));
    });
  });

  group('VioletProfileService.buildProfilePayload — حمولة users/{uid}', () {
    test('تحوي كل الحقول الأساسية بلا كلمة مرور', () {
      final now = DateTime.utc(2026, 10, 22, 9, 30);
      final p = VioletProfileService.buildProfilePayload(
        uid: 'uid-abc-123',
        displayName: 'أحمد',
        email: 'ahmed@test.com',
        createdAt: now,
      );

      expect(p['uid'], 'uid-abc-123');
      expect(p['displayName'], 'أحمد');
      expect(p['email'], 'ahmed@test.com');
      expect(p['createdAt'], isA<Timestamp>());
      expect(p['updatedAt'], isA<Timestamp>());
      expect(p.containsKey('password'), isFalse,
          reason: 'كلمة المرور ممنوعة في Firestore إطلاقاً');
      expect(p.containsKey('photoUrl'), isFalse,
          reason: 'photoUrl اختياري — يُحذف إن كان فارغاً');
    });

    test('photoUrl اختياري يظهر عند توفره فقط', () {
      final p = VioletProfileService.buildProfilePayload(
        uid: 'u',
        displayName: 'Sara',
        email: 's@x.co',
        photoUrl: 'https://example.com/a.png',
      );
      expect(p['photoUrl'], 'https://example.com/a.png');
    });

    test('إعادة المحاولة بنفس البيانات تنتج نفس الحمولة (idempotent)', () {
      final now = DateTime.utc(2026, 10, 22);
      final a = VioletProfileService.buildProfilePayload(
          uid: 'u1', displayName: 'Ali', email: 'a@b.co', createdAt: now);
      final b = VioletProfileService.buildProfilePayload(
          uid: 'u1', displayName: 'Ali', email: 'a@b.co', createdAt: now);
      expect(a.toString(), b.toString());
    });
  });

  group('VioletAuthService — وضع legacy (بلا Firebase)', () {
    final svc = VioletAuthService.withAuth(null);

    test('available=false والحساب فارغ', () {
      expect(svc.available, isFalse);
      expect(svc.currentUser, isNull);
    });

    test('bث الحساب يرمي VioletUnavailableException', () async {
      expect(
        () => svc.signIn('a@b.co', 'password123'),
        throwsA(isA<VioletUnavailableException>()),
      );
      expect(
        () => svc.sendPasswordReset('a@b.co'),
        throwsA(isA<VioletUnavailableException>()),
      );
    });

    test('بث الجلسة فارغ ولا يعلق المستمع', () async {
      var got = false;
      final sub = svc.authStateChanges.listen((_) => got = true);
      await Future<void>.delayed(Duration.zero);
      expect(got, isFalse);
      await sub.cancel();
    });
  });

  group('VioletSession', () {
    test('يساوي على uid والبريد (قابل للمقارنة في الواجهة)', () {
      const a = VioletSession(uid: 'u', email: 'x@y.co');
      const b = VioletSession(uid: 'u', email: 'x@y.co');
      const c = VioletSession(uid: 'u', email: 'z@y.co');
      expect(a, equals(b));
      expect(a == c, isFalse);
    });
  });
}

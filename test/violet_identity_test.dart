import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
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

    test('يقتطع الأسماء اللاتينية الطويلة (>20) ولا يمسّ الأقصر', () {
      // 17 حرفاً — أقل من الحد: تعاد كاملة (لا substring بحد زائد).
      expect(VioletValidators.deriveUsername('AlexanderHamilton', 'x@y.co'),
          'alexanderhamilton');
      // 25 حرفاً — يُقتطع فعلياً إلى 20.
      final long = VioletValidators.deriveUsername(
          'AlexanderHamiltonTheThird', 'x@y.co');
      expect(long.length, 20);
      expect(long, 'alexanderhamiltonthe');
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

    test('رفض Firestore (permission-denied) يعطي رسالة قابلة للتنفيذ', () {
      // الحالة الميدانية الموثقة (v0.1.3 على جهاز المالك): دخول Google
      // ينجح ثم معاملة users/{uid} تُرفض لأن قواعد firestore.rules
      // غير منشورة على Console. الرسالة يجب أن تسمّي الإجراء المطلوب
      // (نشر القواعد) بدل التشخيص العام بالرمز.
      const e = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
        message:
            'The caller does not have permission to execute the specified operation.',
      );
      final ar = VioletAuthErrors.messageAr(e);
      expect(ar, contains('قاعدة البيانات'));
      expect(ar, contains('firestore.rules'));
      expect(ar, contains('Publish'));
      // ليست رسالة التشخيص العام (v0.1.3) ولا النص القديم الغامض.
      expect(ar, isNot(contains('رمز:')));
      expect(ar, isNot(contains('تحقق من البيانات والاتصال')));
      expect(VioletAuthErrors.messageEn(e), contains('firestore.rules'));
    });

    test('انقطاع Firestore (unavailable) يرجع رسالة شبكة واضحة', () {
      const e = FirebaseException(
          plugin: 'cloud_firestore', code: 'unavailable');
      expect(VioletAuthErrors.messageAr(e), contains('تحقق من الإنترنت'));
      const t = FirebaseException(
          plugin: 'cloud_firestore', code: 'deadline-exceeded');
      expect(VioletAuthErrors.messageAr(t), contains('تحقق من الإنترنت'));
    });

    test('FirebaseException أخرى تظل تمر عبر التشخيص العام الصادق', () {
      const e = FirebaseException(
          plugin: 'cloud_firestore', code: 'some-future-code');
      final ar = VioletAuthErrors.messageAr(e);
      expect(ar, contains('رمز:'));
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

  // -----------------------------------------------------------------
  // v0.1.1 — تسجيل الدخول عبر Google
  // -----------------------------------------------------------------
  group('VioletMessagingKey — مفتاح المراسلة المولّد لحسابات Google', () {
    test('40 حرفاً من الأبجدية الآمنة حصراً', () {
      final k = VioletMessagingKey.generate();
      expect(k.length, 40);
      expect(VioletMessagingKey.looksGenerated(k), isTrue);
      expect(
        k.split('').every(VioletMessagingKey.alphabet.contains),
        isTrue,
      );
    });

    test('توليدان متتاليان لا ينتجان نفس المفتاح (عشوائية فعلية)', () {
      final keys = {
        for (var i = 0; i < 20; i++) VioletMessagingKey.generate(),
      };
      expect(keys.length, 20, reason: 'تصادم 20 مفتاحاً مستحيل عملياً');
    });

    test('looksGenerated يرفض القصير والطويل والحرف الغريب', () {
      expect(VioletMessagingKey.looksGenerated(''), isFalse);
      expect(VioletMessagingKey.looksGenerated('a' * 39), isFalse);
      expect(VioletMessagingKey.looksGenerated('a' * 41), isFalse);
      // 0 و1 وl وo ممنوعة عمداً من الأبجدية (قابلية قراءة).
      expect(VioletMessagingKey.looksGenerated('0' * 40), isFalse);
      expect(VioletMessagingKey.looksGenerated('${'a' * 39}l'), isFalse);
      expect(VioletMessagingKey.looksGenerated('${'a' * 39}o'), isFalse);
    });
  });

  group('VioletAuthErrors — أخطاء Google Sign-In (v0.1.1)', () {
    test('DEVELOPER_ERROR/10/sign_in_failed توضح أن التفعيل من Console', () {
      for (final code in const ['sign_in_failed', 'DEVELOPER_ERROR', '10']) {
        final ar = VioletAuthErrors.messageAr(VioletAuthFailure(code, ''));
        expect(ar, contains('Google'), reason: code);
        expect(ar, contains('Firebase'), reason: code);
        final en = VioletAuthErrors.messageEn(VioletAuthFailure(code, ''));
        expect(en.toLowerCase(), contains('not enabled'), reason: code);
      }
    });

    test('أخطاء شبكة Google ترجع رسالة اتصال واضحة', () {
      expect(
        VioletAuthErrors.messageAr(const VioletAuthFailure('network_error', '')),
        contains('خدمات Google'),
      );
      expect(
        VioletAuthErrors.messageAr(const VioletAuthFailure('7', '')),
        contains('خدمات Google'),
      );
    });

    test('أكواد 12500/12502 ترجع رسالة إعادة محاولة', () {
      expect(
        VioletAuthErrors.messageAr(const VioletAuthFailure('12500', '')),
        contains('أعد المحاولة'),
      );
      expect(
        VioletAuthErrors.messageAr(const VioletAuthFailure('12502', '')),
        contains('أعد المحاولة'),
      );
    });

    test('PlatformException المغلف (sign_in_failed من المنصة) يُفهرس صح', () {
      // المحلل النصي يلتقط الكود الأول من: PlatformException(sign_in_failed, …)
      final e = Exception('PlatformException(sign_in_failed, '
          'com.google.android.gms.common.ApiException: 10: DEVELOPER_ERROR)');
      expect(VioletAuthErrors.messageAr(e), contains('Google'));
    });
  });

  group('VioletAuthErrors — تشخيص صادق (v0.1.3)', () {
    test('الفشل المجهول يحمل رمز الخطأ الفعلي في الرسالة', () {
      final msg = VioletAuthErrors.messageAr(Exception('weird-crash-99'));
      expect(msg, contains('تعذر إكمال'));
      expect(msg, contains('weird-crash-99'),
          reason: 'الرمز التشخيصي يظهر في الرسالة — لقطة شاشة تكفي للتشخيص');
    });

    test('الرسالة التشخيصية مقصوصة بأمان عند النصوص الطويلة', () {
      final long = Exception('a' * 200);
      final msg = VioletAuthErrors.messageAr(long);
      expect(msg.length, lessThan(200));
      expect(msg, contains('تعذر إكمال'));
    });

    test('أكواد v0.1.3 الجديدة مُعرَّفة (خدمات Google/اعتماديات)', () {
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('api_not_available', '')),
        contains('خدمات Google'),
      );
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('invalid-credential', '')),
        contains('غير صحيحة'),
      );
      expect(
        VioletAuthErrors.messageAr(
            const VioletAuthFailure('google-no-id-token', '')),
        contains('Google'),
      );
    });
  });

  group('VioletGoogleCanceled — الإلغاء ليس خطأ', () {
    test('toString مميز للتعرف عليه في المسارات', () {
      expect(const VioletGoogleCanceled().toString(), 'VioletGoogleCanceled');
    });
  });

  group('VioletAuthService — Google في وضع legacy', () {
    final svc = VioletAuthService.withAuth(null);

    test('signInWithGoogle يرمي VioletUnavailableException بلا Firebase', () {
      expect(
        () => svc.signInWithGoogle(),
        throwsA(isA<VioletUnavailableException>()),
      );
    });

    test('googleSignOut في وضع legacy لا يرمي (سقوط آمن)', () async {
      await expectLater(svc.googleSignOut(), completes);
    });
  });
}

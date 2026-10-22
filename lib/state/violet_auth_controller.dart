import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/logging/app_logger.dart';
import '../core/config/app_config.dart';
import 'app_services.dart';
import 'auth_controller.dart';
import '../services/violet_auth_service.dart';
import '../services/violet_profile_service.dart';

/// ============================================================
/// VioletAuthController — تنسيق طبقة هوية Violet Chat.
/// ============================================================
/// المسؤوليات:
/// 1) كشف توفر Firebase وقت التشغيل (firebaseReady) — عند غيابه
///    تعرض الواجهة تدفق المصادقة القائم بلا أي انحدار وظيفي.
/// 2) تدفقات الحساب: إنشاء / دخول / خروج / استعادة كلمة المرور،
///    مع التحقق المسبق ومنع الإرسال المزدوج (busy).
/// 3) إنشاء ملف Firestore users/{uid} بعد التسجيل الناجح.
/// 4) الجسر إلى نظام المراسلة (Supabase): جلسة المراسلة تُفتح
///    بنفس البريد/كلمة المرور اللذين أدخلهما المستخدم للتو في
///    الذاكرة فقط — كلمة المرور لا تُخزّن في أي مكان إطلاقاً
///    (لا Firestore، لا SharedPreferences، لا ملفات محلية).
/// 5) توجيه الواجهة: authStateChanges → إشعار المستمعين، والبوابة
///    في app.dart تقود الشاشة المناسبة حسب حالة الجلستين.
class VioletAuthController extends ChangeNotifier {
  VioletAuthController({
    required this.services,
    required this.auth,
    VioletAuthService? violet,
    VioletProfileService? profiles,
  })  : violet = violet ?? VioletAuthService(),
        violetProfiles = profiles ?? VioletProfileService();

  final AppServices services;

  /// متحكم المصادقة/التمهيد القائم — جسر المراسلة يستعمله حرفياً
  /// (signUp/signIn + bootstrap) فتبقى كل ميزات التشفير كما هي.
  final AuthController auth;

  final VioletAuthService violet;
  final VioletProfileService violetProfiles;

  /// تخزين مشفر بجهاز (Android Keystore) — يُحفظ فيه مفتاح المراسلة
  /// المولّد لحسابات Google فقط (ليس كلمات مرور المستخدمين).
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static String _messagingKeyStorageId(String uid) => 'violet_msg_key_$uid';

  bool _busy = false;
  bool get busy => _busy;

  String? _errorAr;
  String? get errorAr => _errorAr;

  String? _infoAr;
  String? get infoAr => _infoAr;

  /// جلسة Firebase الحالية (null = غير مسجل على هوية Violet).
  VioletSession? get violetSession {
    final u = violet.currentUser;
    return u == null ? null : VioletSession.fromUser(u);
  }

  /// جلسة Firebase حية بينما جلسة المراسلة ساقطة — الواجهة تعرض
  /// شاشة الدخول بملاحظة «أعد إدخال كلمة المرور للمزامنة».
  bool get needsMessagingSync =>
      violetSession != null && !auth.signedIn;

  // ----------------------------------------------------------------
  // تهيئة Firebase (تُستدعى مرة واحدة من app_bootstrap)
  // ----------------------------------------------------------------
  static Future<bool> initFirebase() async {
    if (!AppConfig.enableVioletIdentity) return false;
    try {
      await Firebase.initializeApp();
      // فحص إضافي: بعض الأجهزة تهيئ بلا services — جرب الوصول للمنصة.
      FirebaseAuth.instance.app.name;
      AppLogger.i('violet-auth', 'firebase ready');
      return true;
    } catch (e) {
      // google-services.json غائب أو المنصة غير مدعومة — وضع legacy.
      AppLogger.w('violet-auth', 'firebase unavailable — legacy auth', e);
      return false;
    }
  }

  // ----------------------------------------------------------------
  // إنشاء حساب Violet كامل التدفق
  // ----------------------------------------------------------------
  Future<bool> violetSignUp({
    required String displayName,
    required String email,
    required String password,
  }) async {
    return _run(() async {
      // 1) التحقق من الحقول (نقي — رسائل عربية جاهزة).
      final vName = VioletValidators.displayName(displayName);
      if (vName != null) return _fail(vName);
      final vEmail = VioletValidators.email(email);
      if (vEmail != null) return _fail(vEmail);
      final vPass = VioletValidators.password(password);
      if (vPass != null) return _fail(vPass);

      // 2) Firebase Authentication — مالك بيانات الاعتماد الوحيد.
      final user = await violet.signUp(
        displayName: displayName.trim(),
        email: email.trim(),
        password: password,
      );

      // 3) ملف Firestore (آمن: معاملة بلا كتابة فوق موجود).
      await violetProfiles.ensureProfile(
        uid: user.uid,
        displayName: displayName.trim(),
        email: email.trim(),
        photoUrl: user.photoURL,
      );

      // 4) الجسر: فتح جلسة المراسلة بنفس البيانات (في الذاكرة فقط).
      final bridge = await _bridgeMessaging(
        email: email.trim(),
        password: password,
        displayName: displayName.trim(),
      );
      if (bridge != null) return _fail(bridge);

      _infoAr = 'تم إنشاء حساب Violet Chat — مرحباً بك';
      return true;
    });
  }

  // ----------------------------------------------------------------
  // تسجيل الدخول (Violet) + مزامنة المراسلة
  // ----------------------------------------------------------------
  Future<bool> violetSignIn(String email, String password) async {
    return _run(() async {
      final vEmail = VioletValidators.email(email);
      if (vEmail != null) return _fail(vEmail);
      final vPass = VioletValidators.password(password);
      if (vPass != null) return _fail(vPass);

      await violet.signIn(email.trim(), password);

      final bridge = await _bridgeMessaging(
        email: email.trim(),
        password: password,
      );
      if (bridge != null) return _fail(bridge);

      _infoAr = null;
      return true;
    });
  }

  // ----------------------------------------------------------------
  // استعادة كلمة المرور (بريد من Firebase)
  // ----------------------------------------------------------------
  Future<bool> sendVioletReset(String email) async {
    return _run(() async {
      final vEmail = VioletValidators.email(email);
      if (vEmail != null) return _fail(vEmail);
      await violet.sendPasswordReset(email.trim());
      _infoAr = 'أرسلنا رابط استعادة كلمة المرور إلى بريدك';
      return true;
    });
  }

  // ----------------------------------------------------------------
  // تسجيل الدخول عبر Google (v0.1.1)
  // ----------------------------------------------------------------

  /// التدفق الكامل لزر «المتابعة عبر Google»:
  /// 1) اعتماد Google → Firebase (الخدمة)
  /// 2) ملف Firestore (معاملة آمنة بلا كتابة فوق موجود)
  /// 3) جسر المراسلة: حساب Google بلا كلمة مرور، بينما نظام
  ///    المراسلة يتطلب بريداً وكلمة مرور → مفتاح عشوائي مشفر
  ///    يُولّد مرة (وُيُخزن مشفراً على الجهاز) وينشئ جلسة المراسلة.
  Future<bool> violetGoogleSignIn() {
    return _run(() async {
      // 1) Firebase عبر بيانات اعتماد Google.
      final user = await violet.signInWithGoogle();

      final email = (user.email ?? '').trim();
      if (email.isEmpty) {
        // حساب Google بلا بريد ظاهر (نادر جداً) — نخرج بوضوح.
        await violet.signOut();
        return _fail('تعذر معرفة بريد حساب Google — جرّب الدخول بالبريد');
      }

      // 2) ملف Firestore — الاسم من حساب Google (موجود دائماً تقريباً).
      await violetProfiles.ensureProfile(
        uid: user.uid,
        displayName: (user.displayName ?? email.split('@').first).trim(),
        email: email,
        photoUrl: user.photoURL,
      );

      // 3) جسر المراسلة.
      final bridge = await _bridgeMessagingGoogle(user);
      if (bridge != null) return _fail(bridge);

      _infoAr = 'مرحباً بك في Violet Chat';
      return true;
    });
  }

  /// جسر المراسلة لحسابات Google:
  /// أ) مفتاح مخزن مشفراً من دخول سابق → دخول مباشر.
  /// ب) لا مفتاح → توليد مفتاح جديد + إنشاء حساب مراسلة
  ///    (autoconfirm على الخادم يمنح جلسة فورية) ثم تخزينه مشفراً.
  /// ج) البريد مسجل مسبقاً على المراسلة بكلمة مرور أخرى (مثلاً
  ///    مستخدم DRS NEXORA القديم) → رسالة توجيه واضحة.
  Future<String?> _bridgeMessagingGoogle(User user) async {
    final email = (user.email ?? '').trim();
    if (email.isEmpty) return 'تعذر معرفة بريد حساب Google';
    final storageId = _messagingKeyStorageId(user.uid);

    // أ) مفتاح سابق مخزن على هذا الجهاز؟
    try {
      final stored = await _secure.read(key: storageId);
      if (stored != null && stored.length >= 8) {
        if (services.auth.isSignedIn &&
            services.auth.email?.toLowerCase() != email.toLowerCase()) {
          await services.onSignedOut();
          await services.auth.signOut();
        }
        if (!services.auth.isSignedIn) {
          await services.auth.signIn(email, stored);
        }
        await auth.bootstrap();
        return null;
      }
    } catch (e) {
      AppLogger.w('violet-auth', 'stored messaging key failed', e);
      // نكمل للمسار (ب) — المفتاح المخزن قد يكون قديماً.
    }

    // ب) توليد مفتاح جديد وإنشاء حساب المراسلة أول مرة.
    final fresh = VioletMessagingKey.generate();
    try {
      final username = VioletValidators.deriveUsername(
          user.displayName ?? '', email);
      await services.auth.signUp(email, fresh, username);
      // حفظ المفتاح فور نجاح الإنشاء (قبل فحص الجلسة) — إن لم تُمنح
      // جلسة فورية (autoconfirm معطل) يعيد المستخدم المحاولة بعد
      // تأكيد البريد ويدخل عبر المسار (أ) بالمفتاح المخزن.
      await _secure.write(key: storageId, value: fresh);
      if (auth.signedIn) {
        await auth.bootstrap();
        return null;
      }
      // autoconfirm معطل على الخادم → بلا جلسة فورية.
      return 'تم إنشاء الحساب — أكّد بريدك الإلكتروني ثم أعد المحاولة';
    } catch (signUpErr) {
      final su = signUpErr.toString().toLowerCase();
      if (su.contains('already registered') ||
          su.contains('already been registered')) {
        // ج) حساب مراسلة قائم ببيانات مختلفة (مستخدم سابق أو
        //    إعادة تثبيت فقدت المفتاح المشفر) — توجيه صريح.
        return 'هذا البريد له حساب مراسلة بكلمة مرور مختلفة — '
            'استخدم «حساب مراسلة قائم» للدخول بالبريد وكلمة المرور، '
            'أو استعد كلمة المرور من شاشة الدخول';
      }
      AppLogger.e('violet-auth', 'google messaging bridge failed', signUpErr);
      return VioletAuthErrors.messageAr(signUpErr);
    }
  }
  // ----------------------------------------------------------------
  // تسجيل الخروج من الجلستين معاً
  // ----------------------------------------------------------------
  Future<void> violetSignOut() async {
    try {
      await services.onSignedOut();
      await services.auth.signOut();
    } catch (e) {
      AppLogger.w('violet-auth', 'messaging sign-out issue', e);
    }
    try {
      await violet.signOut();
    } catch (e) {
      AppLogger.w('violet-auth', 'firebase sign-out issue', e);
    }
    // جلسة Google على الجهاز — حتى لا يعاد اختيار الحساب صامتاً.
    try {
      await violet.googleSignOut();
    } catch (_) {}
    auth.me = null;
    _errorAr = null;
    _infoAr = null;
    notifyListeners();
  }

  /// مسار الحساب القائم (مراسلة فقط — بدون Firebase): يحفظ وصول
  /// مستخدمي DRS NEXORA السابقين لحساباتهم دون أي تغيير.
  Future<bool> legacySignIn(String email, String password) {
    return _run(() async {
      final vEmail = VioletValidators.email(email);
      if (vEmail != null) return _fail(vEmail);
      final vPass = VioletValidators.password(password);
      if (vPass != null) return _fail(vPass);
      await auth.signIn(email.trim(), password);
      await auth.bootstrap();
      return true;
    });
  }

  // ----------------------------------------------------------------
  // الجسر الداخلي إلى نظام المراسلة (Supabase)
  // ----------------------------------------------------------------

  /// يفتح جلسة المراسلة بنفس بيانات الاعتماد المُدخلة للتو.
  /// يعيد رسالة خطأ عربية عند الفشل، أو null عند النجاح.
  Future<String?> _bridgeMessaging({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      if (services.auth.isSignedIn &&
          services.auth.email?.toLowerCase() == email.toLowerCase()) {
        // الجلسة القائمة لنفس البريد — لا فعل.
        await auth.bootstrap();
        return null;
      }
      if (services.auth.isSignedIn) {
        await services.onSignedOut();
        await services.auth.signOut();
      }

      // تسجيل الدخول أولاً (الحساب موجود على الخادم غالباً).
      try {
        await services.auth.signIn(email, password);
        await auth.bootstrap();
        return null;
      } catch (signInErr) {
        final s = signInErr.toString().toLowerCase();
        final badCredentials = s.contains('invalid login credentials');
        if (!badCredentials) rethrow;

        // لا حساب مراسلة بهذه كلمة المرور — إنشاؤه أول مرة.
        try {
          final username = VioletValidators.deriveUsername(
              displayName ?? '', email);
          await services.auth.signUp(email, password, username);
          if (auth.signedIn) {
            await auth.bootstrap();
            return null;
          }
          // autoconfirm معطّل على الخادم → بلا جلسة فورية.
          return 'تم إنشاء الحساب — أكّد بريدك الإلكتروني ثم سجّل الدخول';
        } catch (signUpErr) {
          final su = signUpErr.toString().toLowerCase();
          if (su.contains('already registered') ||
              su.contains('already been registered')) {
            // حساب مراسلة قائم بكلمة مرور أقدم (مثلاً بعد تغييرها
            // عبر استعادة Firebase) — المستخدم يحتاج مزامنة.
            return 'حساب المراسلة لهذا البريد بكلمة مرور مختلفة — '
                'استخدم «حساب مراسلة قائم» أو حدّث كلمة المرور من '
                'استعادة الحساب القائم ثم أعد الدخول';
          }
          rethrow;
        }
      }
    } catch (e) {
      AppLogger.e('violet-auth', 'messaging bridge failed', e);
      return VioletAuthErrors.messageAr(e);
    }
  }

  // ----------------------------------------------------------------
  // أدوات الحالة
  // ----------------------------------------------------------------
  final bool _running = false; // حارس إضافي ضد التزامن (متسق مع busy)

  Future<bool> _run(Future<bool> Function() body) async {
    if (_running || _busy) return false; // منع الإرسال المزدوج
    _busy = true;
    _errorAr = null;
    _infoAr = null;
    notifyListeners();
    try {
      return await body();
    } on VioletGoogleCanceled {
      // المستخدم أغلق منتقي حسابات Google — ليس خطأ؛ صمت تام.
      return false;
    } on VioletUnavailableException {
      return _fail(
          'هوية Violet غير متاحة حالياً — استخدم حساب المراسلة القائم');
    } on FirebaseAuthException catch (e) {
      AppLogger.w('violet-auth', 'firebase error ${e.code}');
      return _fail(VioletAuthErrors.messageAr(e));
    } catch (e) {
      AppLogger.e('violet-auth', 'auth flow failed', e);
      return _fail(VioletAuthErrors.messageAr(e));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  bool _fail(String message) {
    _errorAr = message;
    return false;
  }

  /// استهلاك الرسائل من الواجهة (snackbar مرة واحدة).
  (String?, String?) consumeMessages() {
    final e = _errorAr;
    final i = _infoAr;
    _errorAr = null;
    _infoAr = null;
    return (e, i);
  }
}

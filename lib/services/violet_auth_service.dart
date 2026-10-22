import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/logging/app_logger.dart';

/// ============================================================
/// Violet Chat identity layer — Firebase Authentication.
/// ============================================================
/// طبقة هوية Violet Chat المستقلة (v0.1.0):
/// - إنشاء حساب بالاسم والبريد وكلمة المرور
/// - تسجيل الدخول / الخروج
/// - استعادة كلمة المرور عبر البريد
/// - التحقق من الحقول وخرائط أخطاء واضحة بالعربية والإنجليزية
///
/// Firebase Authentication يتولى بيانات الاعتماد وحدها — لا تُخزّن
/// كلمة المرور في Firestore ولا SharedPreferences ولا ملفات محلية.
///
/// المنطق النقي (التحقق + خرائط الأخطاء) مفصول في VioletValidators
/// وVioletAuthErrors لاختباره بلا منصة/خدمة حية.
class VioletAuthService {
  /// الافتراضي يكتشف تهيئة Firebase الحالية تلقائياً:
  /// تطبيق افتراضي موجود → متاح؛ غير ذلك → وضع legacy.
  VioletAuthService() : _auth = _resolve(), _google = _defaultGoogle;

  /// حقن صريح للاختبارات (mock أو null لإجبار وضع legacy).
  VioletAuthService.withAuth(FirebaseAuth? auth, {GoogleSignIn? google})
      : _auth = auth,
        _google = google ?? _defaultGoogle;

  static FirebaseAuth? _resolve() {
    try {
      final app = Firebase.app();
      return FirebaseAuth.instanceFor(app: app);
    } catch (_) {
      return null;
    }
  }

  /// null يعني «Firebase غير مهيأ على هذه المنصة» — وضع legacy.
  final FirebaseAuth? _auth;

  /// عميل Google Sign-In (v0.1.1) — نطاق البريد والملف الأساسي فقط.
  /// حقن للاختبارات؛ الافتراضي عميل قياسي بنطاق email/profile.
  final GoogleSignIn _google;
  static final GoogleSignIn _defaultGoogle =
      GoogleSignIn(scopes: ['email', 'profile']);

  bool get available => _auth != null;

  User? get currentUser {
    try {
      return _auth?.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// بث حالة المصادقة (استعادة الجلسة تلقائياً بعد إعادة فتح التطبيق —
  /// Firebase يحفظ الجلسة محلياً ويعيد بناء authStateChanges عند الإقلاع).
  Stream<User?> get authStateChanges {
    final a = _auth;
    if (a == null) return const Stream.empty();
    return a.authStateChanges();
  }

  /// إنشاء حساب: Firebase ينشئ المستخدم ثم يحدّث الاسم الظاهر.
  Future<User> signUp({
    required String displayName,
    required String email,
    required String password,
  }) async {
    final a = _auth;
    if (a == null) throw const VioletUnavailableException();
    final cred = await a.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    final user = cred.user;
    if (user != null && (user.displayName ?? '').isEmpty) {
      await user.updateDisplayName(displayName);
      // بعض البروفايدرات تعيد كائناً قديماً — إعادة تحميل للاتساق.
      await user.reload();
    }
    final fresh = a.currentUser;
    if (fresh == null) {
      throw const VioletAuthFailure('user-null', 'تعذر إنشاء الحساب');
    }
    AppLogger.i('violet-auth', 'sign-up ok (${fresh.uid.substring(0, 6)}…)');
    return fresh;
  }

  Future<User> signIn(String email, String password) async {
    final a = _auth;
    if (a == null) throw const VioletUnavailableException();
    final cred = await a.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    final user = cred.user;
    if (user == null) {
      throw const VioletAuthFailure('user-null', 'تعذر تسجيل الدخول');
    }
    return user;
  }

  Future<void> signOut() async {
    final a = _auth;
    if (a == null) return;
    await a.signOut();
  }

  // ----------------------------------------------------------------
  // تسجيل الدخول عبر Google (v0.1.1)
  // ----------------------------------------------------------------

  /// التدفق القياسي: منتقي حسابات Google → رموز ID/Access →
  /// بيانات اعتماد Firebase → جلسة Firebase كاملة.
  ///
  /// - إلغاء المستخدم يرمي [VioletGoogleCanceled] (لا خطأ — صمت UI).
  /// - فشل التهيئة (DEVELOPER_ERROR وغيره) يصل كـFirebaseAuthException
  /// أو PlatformException ويُترجم عبر [VioletAuthErrors].
  Future<User> signInWithGoogle() async {
    final a = _auth;
    if (a == null) throw const VioletUnavailableException();

    final GoogleSignInAccount? googleUser;
    try {
      googleUser = await _google.signIn();
    } on Exception catch (e) {
      // بعض الأجهزة تعيد الإلغاء كاستثناء منصّي وليس null.
      if (_isCancelError(e)) throw const VioletGoogleCanceled();
      rethrow;
    }
    if (googleUser == null) throw const VioletGoogleCanceled();

    final GoogleSignInAuthentication auth;
    try {
      auth = await googleUser.authentication;
    } on Exception catch (e) {
      if (_isCancelError(e)) throw const VioletGoogleCanceled();
      rethrow;
    }

    final cred = GoogleAuthProvider.credential(
      accessToken: auth.accessToken,
      idToken: auth.idToken,
    );
    final userCred = await a.signInWithCredential(cred);
    final user = userCred.user;
    if (user == null) {
      throw const VioletAuthFailure('user-null', 'تعذر تسجيل الدخول عبر Google');
    }
    AppLogger.i(
        'violet-auth', 'google sign-in ok (${user.uid.substring(0, 6)}…)');
    return user;
  }

  /// إلغاء جلسة Google على الجهاز (عند الخروج من التطبيق) — حتى لا
  /// يعيد منتقي الحسابات الاختيار الصامت في الدخول التالي.
  Future<void> googleSignOut() async {
    try {
      await _google.signOut();
    } catch (e) {
      AppLogger.w('violet-auth', 'google sign-out issue', e);
    }
  }

  static bool _isCancelError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('12501') ||
        s.contains('canceled') ||
        s.contains('cancelled') ||
        s.contains('sign_in_canceled');
  }

  /// استعادة كلمة المرور — Firebase يرسل البريد بلغته المضبوطة في
  /// Console. لا redirect مخصص: المستخدم يعود للتطبيق ويسجل دخوله.
  Future<void> sendPasswordReset(String email) async {
    final a = _auth;
    if (a == null) throw const VioletUnavailableException();
    await a.sendPasswordResetEmail(email: email);
  }
}

/// Firebase غير مهيأ (بدون google-services.json أو فشل تهيئة) —
/// الواجهة تعرض تدفق المصادقة القائم بدلاً من هذا المسار.
class VioletUnavailableException implements Exception {
  const VioletUnavailableException();

  @override
  String toString() => 'Violet identity unavailable on this platform';
}

/// فشل مصادقة موحّد بكود معروف (يُترجم عبر VioletAuthErrors).
class VioletAuthFailure implements Exception {
  final String code;
  final String fallbackAr;
  const VioletAuthFailure(this.code, this.fallbackAr);

  @override
  String toString() => 'VioletAuthFailure($code)';
}

/// المستخدم أغلق منتقي حسابات Google — ليس خطأ؛ الواجهة تتجاهله.
class VioletGoogleCanceled implements Exception {
  const VioletGoogleCanceled();

  @override
  String toString() => 'VioletGoogleCanceled';
}

/// ============================================================
/// مفتاح المراسلة المولّد لحسابات Google (v0.1.1).
/// ============================================================
/// حساب Google بلا كلمة مرور، بينما نظام المراسلة يتطلب بريداً
/// وكلمة مرور. الحل: توليد مفتاح عشوائي مشفراً (40 حرفاً من
/// أبجدية آمنة) بـRandom.secure — يُستخدم مرة لإنشاء جلسة
/// المراسلة، ويُحفظ في تخزين الجهاز المشفر (Android Keystore
/// عبر flutter_secure_storage) ليتاح إعادة الدخول لاحقاً.
///
/// ليس كلمة مرور اختارها المستخدم ولا تُرسل لأي مكان غير
/// خادم المراسلة نفسه — ولا يدخل Firestore أبداً.
class VioletMessagingKey {
  VioletMessagingKey._();

  static const String alphabet =
      'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789';

  /// 40 حرفاً ≈ 235 بت عشوائية — يتجاوز قوة أي هجوم عملي.
  static String generate([Random? rng]) {
    final r = rng ?? Random.secure();
    return List.generate(
        40, (_) => alphabet[r.nextInt(alphabet.length)]).join();
  }

  /// فحص نقي: هل السلسلة بمواصفات المفتاح المولّد؟
  static bool looksGenerated(String s) =>
      s.length == 40 && s.split('').every(alphabet.contains);
}

/// ============================================================
/// التحقق من الحقول — منطق نقي (وحدات اختبار بلا Firebase).
/// ============================================================
class VioletValidators {
  VioletValidators._();

  /// صيغة بريد عملية: local@domain.tld (tld ≥ حرفين) — نفس القاعدة
  /// التي كانت على شاشة الدخول القديمة حتى يبقى السلوك متسقاً.
  static final RegExp emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  static String? email(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'أدخل البريد الإلكتروني';
    if (!emailRe.hasMatch(value)) return 'صيغة البريد الإلكتروني غير صحيحة';
    return null;
  }

  /// 8 أحرف على الأقل (متسق مع شاشة الدخول القائمة). Firebase نفسه
  /// يفرض 6 كحد أدنى — التطبيق أصعب عمداً لصالح الأمان.
  static String? password(String? v) {
    if ((v ?? '').length < 8) return 'كلمة المرور 8 أحرف على الأقل';
    return null;
  }

  /// الاسم الظاهر: حرفان على الأقل بعد تقليم الفراغات.
  static String? displayName(String? v) {
    final value = (v ?? '').trim();
    if (value.length < 2) return 'الاسم حرفان على الأقل';
    if (value.length > 40) return 'الاسم طويل جداً (40 حرفاً كحد أقصى)';
    return null;
  }

  /// اشتقاق اسم مستخدم للمراسلة من الاسم الظاهر (الجسر يعتمد
  /// أحرفاً لاتينية/رقمية). إن لم يصلح الاسم نُشتق من البريد.
  static String deriveUsername(String displayName, String email) {
    final base = (displayName.trim().isNotEmpty
            ? displayName.trim()
            : email.split('@').first)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (base.length >= 3) return _clip(base);
    final fromEmail = email.split('@').first.toLowerCase();
    final safe = fromEmail.replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (safe.length >= 3) return _clip(safe);
    return 'violet${base.length}x';
  }

  /// اقتطاع آمن حتى 20 حرفاً (substring بحد يتجاوز الطول يرمي استثناء).
  static String _clip(String s) => s.length <= 20 ? s : s.substring(0, 20);
}

/// ============================================================
/// خرائط أخطاء Firebase → رسائل واضحة (عربي + إنجليزي).
/// ============================================================
class VioletAuthErrors {
  VioletAuthErrors._();

  static const Map<String, (String, String)> _map = {
    'email-already-in-use': (
      'هذا البريد مسجّل مسبقاً — جرّب تسجيل الدخول',
      'This email is already registered — try signing in',
    ),
    'invalid-email': (
      'صيغة البريد الإلكتروني غير صحيحة',
      'Invalid email address format',
    ),
    'weak-password': (
      'كلمة المرور ضعيفة — 6 أحرف على الأقل يفرضها النظام',
      'Weak password — at least 6 characters required',
    ),
    'user-not-found': (
      'لا يوجد حساب بهذا البريد',
      'No account found for this email',
    ),
    'wrong-password': (
      'البريد الإلكتروني أو كلمة المرور غير صحيحة',
      'Incorrect email or password',
    ),
    'invalid-credential': (
      'البريد الإلكتروني أو كلمة المرور غير صحيحة',
      'Incorrect email or password',
    ),
    'user-disabled': (
      'هذا الحساب معطّل — تواصل مع الدعم',
      'This account has been disabled',
    ),
    'too-many-requests': (
      'محاولات كثيرة — انتظر قليلاً ثم أعد المحاولة',
      'Too many attempts — wait a moment and try again',
    ),
    'operation-not-allowed': (
      'تسجيل الحسابات غير مفعّل على الخادم بعد — سيُفعّل قريباً',
      'Email/password sign-up is not enabled yet on the server',
    ),
    'network-request-failed': (
      'تعذر الاتصال بالخادم — تحقق من الإنترنت',
      'Network error — check your connection',
    ),
    'CONFIGURATION_NOT_FOUND': (
      'خدمة الحسابات غير مهيأة على هذا المشروع — تحتاج تفعيلاً من المالك',
      'Authentication is not configured for this project yet',
    ),
    // --- Google Sign-In (v0.1.1) ---
    // ApiException: 10 = DEVELOPER_ERROR — البصمة/الحزمة غير مسجلة
    // أو مزود Google غير مفعّل على مشروع Firebase.
    'sign_in_failed': (
      'تسجيل الدخول عبر Google غير مفعّل على المشروع بعد — يتطلب تفعيلاً '
          'من Firebase Console (إضافة بصمة SHA-1 ثم تمكين Google)',
      'Google sign-in is not enabled for this project yet — requires '
          'Firebase Console setup (SHA-1 fingerprint + enable Google)',
    ),
    'DEVELOPER_ERROR': (
      'تسجيل الدخول عبر Google غير مفعّل على المشروع بعد — يتطلب تفعيلاً '
          'من Firebase Console (إضافة بصمة SHA-1 ثم تمكين Google)',
      'Google sign-in is not enabled for this project yet — requires '
          'Firebase Console setup (SHA-1 fingerprint + enable Google)',
    ),
    '10': (
      'تسجيل الدخول عبر Google غير مفعّل على المشروع بعد — يتطلب تفعيلاً '
          'من Firebase Console (إضافة بصمة SHA-1 ثم تمكين Google)',
      'Google sign-in is not enabled for this project yet — requires '
          'Firebase Console setup (SHA-1 fingerprint + enable Google)',
    ),
    'network_error': (
      'تعذر الاتصال بخدمات Google — تحقق من الإنترنت',
      'Could not reach Google services — check your connection',
    ),
    '7': (
      'تعذر الاتصال بخدمات Google — تحقق من الإنترنت',
      'Could not reach Google services — check your connection',
    ),
    '8': (
      'خطأ داخلي في خدمات Google — أعد المحاولة بعد قليل',
      'Internal Google services error — try again shortly',
    ),
    '12500': (
      'تعذر إكمال الدخول عبر Google — أعد المحاولة',
      'Google sign-in could not complete — try again',
    ),
    '12502': (
      'تعذر إكمال الدخول عبر Google — أعد المحاولة',
      'Google sign-in could not complete — try again',
    ),
  };

  /// رسالة عربية (المسار الأساسي — التطبيق عربي أولاً).
  static String messageAr(Object error) => _pick(error, 0);

  /// رسالة إنجليزية (متاحة للواجهات الإنجليزية وسجلات الدعم).
  static String messageEn(Object error) => _pick(error, 1);

  static String _pick(Object error, int idx) {
    if (error is VioletAuthFailure) {
      final pair = _map[error.code];
      if (pair != null) return idx == 0 ? pair.$1 : pair.$2;
      return idx == 0 ? error.fallbackAr : error.fallbackAr;
    }
    String code = '';
    if (error is FirebaseAuthException) code = error.code;
    if (error is VioletUnavailableException) {
      return idx == 0
          ? 'هوية Violet غير متاحة على هذا الجهاز — استخدم حساب المراسلة القائم'
          : 'Violet identity unavailable — use the legacy messaging account';
    }
    if (code.isEmpty) {
      final s = error.toString();
      // بعض الأخطاء تصل مغلّفة: PlatformException(code, message…)
      final m = RegExp(r'([A-Za-z0-9\-_]+)\s*,').firstMatch(s);
      code = m?.group(1) ?? s;
    }
    final pair = _map[code];
    if (pair != null) return idx == 0 ? pair.$1 : pair.$2;
    return idx == 0
        ? 'تعذر إكمال العملية — تحقق من البيانات والاتصال'
        : 'Could not complete the request — check your data and connection';
  }
}

/// بث موحّد لحالة جلسة Violet لمن يستمع (الواجهة/المتحكم).
@immutable
class VioletSession {
  final String uid;
  final String? email;
  final String? displayName;

  const VioletSession({
    required this.uid,
    this.email,
    this.displayName,
  });

  factory VioletSession.fromUser(User u) => VioletSession(
        uid: u.uid,
        email: u.email,
        displayName: u.displayName,
      );

  @override
  bool operator ==(Object other) =>
      other is VioletSession && other.uid == uid && other.email == email;

  @override
  int get hashCode => Object.hash(uid, email);

  @override
  String toString() => 'VioletSession($uid, $email)';
}

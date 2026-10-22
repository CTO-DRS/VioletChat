import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/logging/app_logger.dart';

/// ============================================================
/// Violet Chat — ملف المستخدم في Cloud Firestore.
/// ============================================================
/// المسار: users/{uid} — المعرّف الأساسي هو UID الصادر عن
/// Firebase Authentication (لا يُستعمل أي معرف محلي).
///
/// الحقول الأساسية: uid, displayName, email, photoUrl (اختياري),
/// createdAt, updatedAt.
///
/// الإنشاء آمن وقابل لإعادة المحاولة: runTransaction تقرأ الوثيقة
/// أولاً — وثيقة موجودة لا تُكتب فوقها أبداً (فقط تحديث توثيقي
/// لـ updatedAt عند الطلب الصريح)، والقراءة عبر القواعد مقصورة
/// على المالك (firestore.rules في جذر المستودع).
class VioletProfileService {
  VioletProfileService({FirebaseFirestore? store})
      : _store = store ?? _defaultStore();

  static FirebaseFirestore? _defaultStore() {
    try {
      return FirebaseFirestore.instance;
    } catch (_) {
      // بدون تهيئة Firebase (وضع legacy) تبقى الخدمة غير متاحة.
      return null;
    }
  }

  final FirebaseFirestore? _store;

  bool get available => _store != null;

  CollectionReference<Map<String, dynamic>>? get _users =>
      _store?.collection('users');

  /// حمولة الملف — نقي وقابل للاختبار بلا Firestore.
  static Map<String, dynamic> buildProfilePayload({
    required String uid,
    required String displayName,
    required String email,
    String? photoUrl,
    DateTime? createdAt,
  }) {
    final now = createdAt ?? DateTime.now().toUtc();
    return {
      'uid': uid,
      'displayName': displayName,
      'email': email,
      if (photoUrl != null && photoUrl.isNotEmpty) 'photoUrl': photoUrl,
      'createdAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
    };
  }

  /// إنشاء الملف بعد التسجيل الناجح. idempotent: إعادة المحاولة بعد
  /// انقطاع شبكة لا تُدمر بيانات موجودة (merge ممنوع على إنشاء جديد
  /// والقراءة داخل المعاملة تحمي من السباق).
  Future<void> ensureProfile({
    required String uid,
    required String displayName,
    required String email,
    String? photoUrl,
  }) async {
    final db = _store;
    if (db == null) {
      throw StateError('VioletProfileService unavailable (no Firebase)');
    }
    final ref = db.collection('users').doc(uid);

    await db.runTransaction((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) {
        // الملف موجود من محاولة سابقة — لا كتابة فوق بيانات المستخدم.
        AppLogger.i('violet-profile', 'profile already exists, keeping it');
        return;
      }
      final payload =
          buildProfilePayload(uid: uid, displayName: displayName, email: email,
              photoUrl: photoUrl);
      tx.set(ref, payload);
    });
    AppLogger.i('violet-profile', 'profile ensured for $uid');
  }

  /// قراءة الملف (null عند عدم الوجود).
  Future<Map<String, dynamic>?> getProfile(String uid) async {
    final ref = _users?.doc(uid);
    if (ref == null) return null;
    final snap = await ref.get(const GetOptions(source: Source.server));
    return snap.exists ? snap.data() : null;
  }

  /// تحديث اسم ظاهر/صورة — يختم updatedAt دائماً.
  Future<void> updateProfile(
    String uid, {
    String? displayName,
    String? photoUrl,
  }) async {
    final ref = _users?.doc(uid);
    if (ref == null) throw StateError('VioletProfileService unavailable');
    final patch = <String, dynamic>{
      'updatedAt': Timestamp.fromDate(DateTime.now().toUtc()),
      if (displayName != null) 'displayName': displayName,
      if (photoUrl != null) 'photoUrl': photoUrl,
    };
    await ref.update(patch);
  }
}

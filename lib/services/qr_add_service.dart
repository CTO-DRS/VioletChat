/// v0.1.9 — إضافة صديق بالباركود: بناء/تحليل حمولة QR.
///
/// الحمولة الرسمية: `violetchat://add/<username>` — يولدها جهاز المالك
/// (شاشة الملف الشخصي) ويمسحه جهاز آخر (منتقي المحادثة الجديدة).
///
/// التحليل متسامح عمداً: أي حساب ميداني يجب أن يصل إلى نفس المعرّف:
///   • `violetchat://add/ahmad`            (الرسمية)
///   • `VIOLETCHAT://ADD/AHMAD`            (ناتج قارئ خارجي يقيس الحالة)
///   • `https://…/add?u=ahmad` أو `?u=`    (روابط مستقبلية)
///   • `@ahmad` / `ahmad `                 (إدخال يدوي/نسخ لصق)
/// المعرّف الناتج يمر عبر نفس قواعد المنصة: [a-z0-9_] بطول 3–20.
class QrAddService {
  QrAddService._();

  /// بادئة الحمولة الرسمية (تُعرض وتُشارك كما هي).
  static const String scheme = 'violetchat://add/';

  /// نمط المعرّف المسموح — مطابق لقاعدة المنصة (3–20 حرفاً).
  static final RegExp _usernameRe = RegExp(r'^[a-z0-9_]{3,20}$');

  /// بناء حمولة QR من معرّف — يُطبّع (أحرف صغيرة، بلا @، بلا فراغات).
  /// يرمي [ArgumentError] على معرّف غير صالح: الأصل لا يصدر رمزاً خاطئاً.
  static String buildPayload(String username) {
    final u = normalize(username);
    if (u == null) {
      throw ArgumentError.value(username, 'username', 'معرّف غير صالح');
    }
    return '$scheme$u';
  }

  /// تحليل أي نص ممسوح/ملصوق إلى معرّف صالح، أو null عند الفشل.
  /// لا يرمي أبداً — نص المستخدم الخارجي غير موثوق.
  static String? parsePayload(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;

    // روابط https تحتوي معامل u= أو username=
    final uri = Uri.tryParse(s);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final q = uri.queryParameters['u'] ?? uri.queryParameters['username'];
      if (q != null && q.trim().isNotEmpty) s = q.trim();
    }

    // إسقاط أي بادئة معروفة (رسمية أو حالة مختلفة أو بارامتر)
    final idx = s.toLowerCase().indexOf(scheme);
    if (idx >= 0) s = s.substring(idx + scheme.length);

    // بادئات تسامح إضافية شائعة من قارئات خارجية
    s = s.replaceFirst(RegExp(r'^@+'), '').trim();

    return normalize(s);
  }

  /// تطبيع معرّف: أحرف صغيرة + إسقاط كل ما ليس [a-z0-9_] ثم فحص الطول.
  /// يُعيد null إذا لم يبقَ معرّف صالح بعد التطبيع.
  static String? normalize(String username) {
    final cleaned =
        username.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (!_usernameRe.hasMatch(cleaned)) return null;
    return cleaned;
  }
}

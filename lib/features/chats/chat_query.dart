import '../../data/models/models.dart';

/// ============================================================
/// v0.1.6 «كل زر له وظيفة» — تصفية محلية فورية نقيّة.
/// ============================================================
/// شريط البحث في الشاشة الرئيسية صار يصفّي القائمة المعروضة
/// لحظياً (محادثات + أصدقاء) دون مغادرة الصفحة — وظيفة مميزة
/// عن «البحث الشامل» (شاشة البحث: مستخدمون + رسائل + محادثاتي).
///
/// المنطق نقي بالكامل (بلا Flutter/Widgets) ليُختبر مباشرة.
/// ============================================================

/// أحرف التشكيل العربية تُحذف قبل المطابقة.
const String _tashkeel = '\u064B\u064C\u064D\u064E\u064F\u0650\u0651\u0652';

/// تطبيع متسامح للنص العربي/اللاتيني قبل المطابقة:
/// - توحيد الألف (أ/إ/آ → ا) والياء/الألف المقصورة (ي/ى) والتاء المربوطة
/// - حذف التشكيل
/// - تحويل اللاتيني إلى صغير
String normalizeAr(String s) {
  final sb = StringBuffer();
  for (final ch in s.runes) {
    final c = String.fromCharCode(ch);
    if (_tashkeel.contains(c)) continue;
    switch (c) {
      case 'أ':
      case 'إ':
      case 'آ':
        sb.write('ا');
      case 'ى':
        sb.write('ي');
      case 'ة':
        sb.write('ه');
      default:
        sb.write(c.toLowerCase());
    }
  }
  return sb.toString();
}

/// هل تطابق المحادثة استعلام التصفية المحلية؟
/// الحقول: اسم المجموعة/عنوان الطرف الآخر + معرّفه + وصف المجموعة.
bool chatMatchesQuery(Chat chat, String rawQuery) {
  final q = normalizeAr(rawQuery.trim());
  if (q.isEmpty) return true;
  final haystack = [
    chat.title,
    if (!chat.isGroup) ...[
      chat.peer?.username ?? '',
      chat.peer?.displayName ?? '',
    ] else ...[
      chat.name,
      if (chat.description != null) chat.description!,
    ],
  ].map(normalizeAr).join('\n');
  return haystack.contains(q);
}

/// هل يطابق الملف الشخصي (صديق/جهة اتصال) استعلام التصفية؟
bool profileMatchesQuery(Profile p, String rawQuery) {
  final q = normalizeAr(rawQuery.trim());
  if (q.isEmpty) return true;
  final haystack =
      [p.displayName, p.username, p.bio ?? ''].map(normalizeAr).join('\n');
  return haystack.contains(q);
}

List<Chat> filterChats(List<Chat> chats, String rawQuery) =>
    rawQuery.trim().isEmpty
        ? List<Chat>.of(chats)
        : chats.where((c) => chatMatchesQuery(c, rawQuery)).toList();

List<Profile> filterProfiles(List<Profile> profiles, String rawQuery) =>
    rawQuery.trim().isEmpty
        ? List<Profile>.of(profiles)
        : profiles.where((p) => profileMatchesQuery(p, rawQuery)).toList();

import 'dart:convert';
import 'dart:io';

import '../core/config/app_config.dart';

/// v0.1.9 — فحص التحديث داخل التطبيق عبر GitHub Releases API.
///
/// منطق التوزيع الحالي: APK منشور على GitHub Releases (رابط عام).
/// التطبيق يسأل `releases/latest` ويقارن `tag_name` بإصداره المحلي —
/// عند وجود أحدث يُعرض حوار ترحيبي برابط التحميل المباشر.
///
/// الفحص:
///   • صامت تماماً عند أي فشل (شبكة/معدل طلبات/JSON غير متوقع) — null.
///   • لا يسأل أكثر من مرة واحدة لكل إطلاق تطبيق (حارس ثابت).
///   • مقارنة الإصدارات دلالية (0.1.9 < 0.1.10) لا نصية.
class UpdateService {
  UpdateService._();

  /// مستودع الإصدارات الرسمي.
  static const String repoOwner = 'CTO-DRS';
  static const String repoName = 'VioletChat';

  /// حارس «مرة واحدة لكل إطلاق» — الفحص الصامت الأول فقط.
  static bool _silentCheckDone = false;

  /// هل جرى الفحص الصامت في هذا الإطلاق؟ (واجهات العرض تستفيد منه
  /// كي لا تكرر السؤال عند كل فتح للإعدادات… الفحص اليدوي مسموح دائماً).
  static bool get silentCheckDone => _silentCheckDone;

  /// تحويل نص إصدار «v0.1.9» / «0.1.9» إلى أجزاء رقمية، أو null.
  static List<int>? parseVersion(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // إسقاط أي لاحقة بناء (0.1.9+16 → 0.1.9)
    final plus = s.indexOf('+');
    if (plus > 0) s = s.substring(0, plus);
    final parts = s.split('.');
    if (parts.length < 2 || parts.length > 4) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    return nums;
  }

  /// مقارنة دلالية: سالب إذا a أقدم، 0 متساويان، موجب إذا a أحدث.
  /// يعامل الأجزاء الغائبة كصفر (0.1 = 0.1.0) — النمط القياسي semver.
  static int compareVersions(String a, String b) {
    final va = parseVersion(a);
    final vb = parseVersion(b);
    if (va == null || vb == null) return 0; // غير قابل للمقارنة = لا ترقية
    final len = va.length > vb.length ? va.length : vb.length;
    for (var i = 0; i < len; i++) {
      final x = i < va.length ? va[i] : 0;
      final y = i < vb.length ? vb[i] : 0;
      if (x != y) return x.compareTo(y);
    }
    return 0;
  }

  /// هل الإصدار الممسوس أحدث من المحلي؟
  static bool isNewer(String remote, String local) =>
      compareVersions(remote, local) > 0;

  /// نتيجة الفحص الناجحة.
  static Future<UpdateInfo?> checkLatest({String? currentVersion}) async {
    final cur = currentVersion ?? AppConfig.appVersion;
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      final req = await client.getUrl(Uri.parse(
          'https://api.github.com/repos/$repoOwner/$repoName/releases/latest'));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'VioletChat-App');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        client.close();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      client.close();
      final json = jsonDecode(body) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?) ?? '';
      final url = (json['html_url'] as String?) ??
          'https://github.com/$repoOwner/$repoName/releases';
      if (parseVersion(tag) == null) return null;
      return UpdateInfo(
        latestVersion: tag,
        downloadUrl: url,
        isUpgradeAvailable: isNewer(tag, cur),
      );
    } catch (_) {
      return null; // صامت — بلا إزعاج عند غياب الشبكة
    }
  }

  /// الفحص الصامت عند بدء التطبيق — مرة واحدة لكل إطلاق.
  static Future<UpdateInfo?> silentCheck() async {
    if (_silentCheckDone) return null;
    _silentCheckDone = true;
    return checkLatest();
  }
}

/// معلومات إصدار أحدث مكتشف.
class UpdateInfo {
  final String latestVersion; // مثل v0.1.9
  final String downloadUrl; // صفحة الإصدار (أو رابط APK لاحقاً)
  final bool isUpgradeAvailable;

  const UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.isUpgradeAvailable,
  });
}

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config/app_config.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';

/// v0.1.9 — حوار الترقية المشترك: يُستدعى من الفحص الصامت عند بدء
/// التطبيق (شاشة المحادثات) ومن الفحص اليدوي (الإعدادات).
Future<void> showUpgradeDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    builder: (dlgCtx) => AlertDialog(
      title: Text('تحديث جديد متاح — ${info.latestVersion}',
          textAlign: TextAlign.right,
          style: const TextStyle(fontWeight: FontWeight.w800)),
      content: Text(
        'إصدارك الحالي ${AppConfig.appVersion}. الإصدار الجديد يحمل '
        'تحسينات وإصلاحات — ننصح بالتحديث من صفحة الإصدارات الرسمية '
        '(تثبيت الحزمة فوق القديم يحافظ على بياناتك ومفاتيحك).',
        textAlign: TextAlign.right,
        style: TextStyle(
            height: 1.6,
            color: Theme.of(dlgCtx).textTheme.bodyMedium?.color),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dlgCtx),
          child: const Text('لاحقاً'),
        ),
        FilledButton.icon(
          onPressed: () async {
            Navigator.pop(dlgCtx);
            final uri = Uri.parse(info.downloadUrl);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
          style: FilledButton.styleFrom(
              backgroundColor: AppTheme.brandPrimary),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('تحميل التحديث'),
        ),
      ],
    ),
  );
}

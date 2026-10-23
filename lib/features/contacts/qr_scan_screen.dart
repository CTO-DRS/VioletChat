import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/qr_add_service.dart';
import '../../theme/app_theme.dart';

/// v0.1.9 — شاشة مسح رمز إضافة صديق.
///
/// تعرض الكاميرا مع إطار توجيه، وعند التقاط رمز صالح تعيد اسم المستخدم
/// عبر Navigator.pop(context, username). الرموز غير الصالحة تُعرض
/// كملاحظة خفيفة داخل الشاشة بلا إنهاء — الكاميرا تظل تعمل.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _camera = MobileScannerController(
    detectionTimeoutMs: 800, // ثبات قبل القبول
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  String? _note;

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || !mounted) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final username = QrAddService.parsePayload(raw);
      if (username == null) {
        // رمز QR عادي (ليس رمز إضافة Violet) — ننوّه ولا ننهي.
        setState(() => _note = 'هذا الرمز ليس رمز إضافة Violet Chat');
        return;
      }
      _done = true;
      Navigator.pop(context, username);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح رمز الإضافة',
            style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: true,
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _onDetect,
            errorBuilder: (ctx, error) => _cameraError(ctx, error),
          ),
          // إطار توجيه مركزي
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color:
                        AppTheme.brandSecondary.withValues(alpha: 0.9),
                    width: 3),
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(18),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark
                      ? AppTheme.darkSurface.withValues(alpha: 0.92)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'وجّه الكاميرا نحو رمز QR المعروض على جهاز الصديق\n'
                      '(الملف الشخصي ← رمز QR الخاص بي)',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.color),
                    ),
                    if (_note != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        _note!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12,
                            color: AppTheme.errorColor,
                            fontWeight: FontWeight.w700),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cameraError(
      BuildContext ctx, MobileScannerException error, Widget? child) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                size: 52, color: AppTheme.brandSecondary),
            const SizedBox(height: 14),
            const Text('تعذر تشغيل الكاميرا',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(
              'تأكد من منح إذن الكاميرا للتطبيق من إعدادات النظام ثم أعد المحاولة.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: Theme.of(ctx).textTheme.bodyMedium?.color),
            ),
          ],
        ),
      ),
    );
  }
}

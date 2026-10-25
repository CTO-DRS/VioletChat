import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'core/config/app_config.dart';
import 'core/logging/app_logger.dart';
import 'core/storage/local_database.dart';
import 'core/storage/session_vault.dart';
import 'crypto/identity.dart';
import 'state/app_services.dart';
import 'state/auth_controller.dart';
import 'state/chats_controller.dart';
import 'state/settings_controller.dart';
import 'state/stories_controller.dart';
import 'state/violet_auth_controller.dart';
import 'widgets/brand.dart';

/// Boot root — renders the branded screen IMMEDIATELY, then runs every
/// startup step with visible progress and a RECOVERABLE error screen.
///
/// WHY THIS EXISTS: before v0.1.0 all initialisation happened before
/// runApp(); any failure (corrupt local DB, broken Keystore on some
/// devices after reinstall/restore, …) left the user with an eternal
/// black screen and zero feedback. Now the first frame is instant and
/// failures are visible with retry / local-crypto-reset actions.
class VioletBootstrap extends StatefulWidget {
  const VioletBootstrap({super.key});

  @override
  State<VioletBootstrap> createState() => _VioletBootstrapState();
}

enum _Phase { loading, error, ready }

class _VioletBootstrapState extends State<VioletBootstrap> {
  _Phase _phase = _Phase.loading;
  String _step = '';
  String _errorDetail = '';

  bool _booting = false;
  bool _supabaseReady = false;

  AppServices? _services;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    if (_booting) return;
    _booting = true;
    setState(() {
      _phase = _Phase.loading;
      _errorDetail = '';
    });

    try {
      // 0) هوية Violet Chat (v0.1.0): تهيئة Firebase إن توفرت —
      //    لا ترمي أبداً (غياب google-services.json = وضع legacy).
      _setStep('تهيئة هوية Violet…');
      await VioletAuthController.initFirebase();

      // 1) Backend (public URL + publishable key only).
      //    audit 2026-10-25: the messaging session now persists in the
      //    Keystore-backed vault instead of plaintext SharedPreferences;
      //    the vault migrates any pre-existing plaintext copy on first
      //    boot (same storage key, zero user-visible effect).
      _setStep('تهيئة الاتصال بالخادم…');
      if (!_supabaseReady) {
        await Supabase.initialize(
          url: AppConfig.supabaseUrl,
          publishableKey: AppConfig.supabasePublishableKey,
          authOptions: FlutterAuthClientOptions(
            localStorage: SecureVaultLocalStorage(
              persistSessionKey: SecureVaultLocalStorage.keyFor(
                  AppConfig.supabaseUrl),
            ),
          ),
        );
        _supabaseReady = true;
      }

      // 2) Local DB + its encryption key bridge (self-healing open —
      //    a corrupt database file is recreated, see LocalDatabase).
      _setStep('فتح قاعدة البيانات المحلية…');
      IdentityBridge.register(IdentityManager.dbKey);
      await LocalDatabase.instance;

      // 3) Crypto identity (Keystore-resilient — see IdentityManager).
      //    Watchdog: identity load itself carries internal timeouts, and
      //    this outer guard guarantees the splash can never hang forever
      //    — worst case the user gets the error screen with retry/reset
      //    instead of an eternal spinner.
      _setStep('تجهيز مفاتيح التشفير…');
      final services =
          await AppServices.create().timeout(const Duration(seconds: 60));
      _services = services;

      // 4) Best-effort cleanup of plaintext temp media from previous
      //    sessions (decrypted video/file shares live in system temp;
      //    v0.1.0 removes anything older than 30 minutes). Never a
      //    boot blocker.
      _cleanupDecryptedTempMedia();

      setState(() => _phase = _Phase.ready);
    } catch (error, stack) {
      AppLogger.e('bootstrap', 'startup failed', error, stack);
      setState(() {
        _phase = _Phase.error;
        _errorDetail = _sanitize(error.toString());
      });
    } finally {
      _booting = false;
    }
  }

  /// Deletes decrypted-media temp directories ('nexora_share' from
  /// file shares and 'nexora_video' from the in-app player) that are
  /// older than 30 minutes, so plaintext never lingers on disk.
  void _cleanupDecryptedTempMedia() {
    try {
      final now = DateTime.now();
      for (final entity in Directory.systemTemp.listSync()) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (entity is! Directory ||
            !(name.startsWith('nexora_share') ||
                name.startsWith('nexora_video'))) {
          continue;
        }
        final age = now.difference(entity.statSync().modified);
        if (age > const Duration(minutes: 30)) {
          entity.deleteSync(recursive: true);
        }
      }
    } catch (e) {
      AppLogger.w('bootstrap', 'temp media cleanup skipped', e);
    }
  }

  /// Last-resort recovery: wipe the LOCAL crypto state (Keystore keys +
  /// local database) and boot again. Server-side identity re-registers
  /// on next sign-in (documented recovery path). No server data is
  /// touched; old server messages stay E2EE-undecryptable as designed.
  Future<void> _resetLocalCrypto() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إعادة تعيين بيانات التشفير المحلية؟'),
        content: const Text(
          'سيتم حذف مفاتيح هذا الجهاز وقاعدة البيانات المحلية فقط، ثم '
          'إعادة توليدها. لن تُحذف أي بيانات من الخادم. قد تصبح الرسائل '
          'القديمة غير قابلة للفك على هذا الجهاز (هذا متوقع في التشفير '
          'الطرف-لطرف).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('إعادة التعيين'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await IdentityManager.wipe();
    } catch (_) {
      AppLogger.w('bootstrap', 'identity wipe failed (continuing)');
    }
    try {
      await LocalDatabase.deleteFile();
    } catch (_) {
      AppLogger.w('bootstrap', 'db delete failed (continuing)');
    }
    _run();
  }

  void _setStep(String s) {
    if (!mounted) return;
    setState(() => _step = s);
  }

  /// Strip any credential-looking token from an error string before
  /// showing it on screen (defence in depth; startup errors normally
  /// contain none).
  static String _sanitize(String raw) {
    var s = raw.replaceAll(
        RegExp(r'sb_publishable_[A-Za-z0-9_\-]+'), '[مفتاح عام محجوب]');
    s = s.replaceAll(RegExp(r'Bearer\s+[A-Za-z0-9._\-]+', caseSensitive: false),
        'Bearer [محجوب]');
    if (s.length > 400) s = '${s.substring(0, 400)}…';
    return s;
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.loading:
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: _BootSplash(step: _step),
        );
      case _Phase.error:
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          home: _BootErrorScreen(
            detail: _errorDetail,
            onRetry: _run,
            onReset: _resetLocalCrypto,
          ),
        );
      case _Phase.ready:
        final services = _services!;
        return MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            ChangeNotifierProvider(
                create: (_) => SettingsController(services)..load()),
            ChangeNotifierProvider(create: (_) => AuthController(services)),
            ChangeNotifierProvider(
              create: (ctx) => VioletAuthController(
                services: services,
                auth: ctx.read<AuthController>(),
              ),
            ),
            ChangeNotifierProvider(
              create: (ctx) =>
                  ChatsController(services, ctx.read<AuthController>()),
            ),
            ChangeNotifierProvider(
              create: (ctx) => StoriesController(
                  services, ctx.read<AuthController>())
                ..start(),
            ),
          ],
          child: const VioletApp(),
        );
    }
  }
}

/// Branded boot splash — identical background to the native Android
/// splash (#140B2E) so the transition is seamless, with the current
/// boot step visible at all times.
class _BootSplash extends StatelessWidget {
  final String step;
  const _BootSplash({required this.step});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF140B2E),
      child: SafeArea(
        child: Center(
          child: _BootContent(step: step),
        ),
      ),
    );
  }
}

class _BootContent extends StatelessWidget {
  final String step;
  const _BootContent({required this.step});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const BrandLogo(size: 88, showName: true),
        const SizedBox(height: 40),
        const SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            color: Color(0xFFA78BFA),
            strokeWidth: 2.6,
          ),
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: Text(
            step,
            key: ValueKey(step),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
      ],
    );
  }
}

/// Readable, recoverable startup failure — never a black screen.
class _BootErrorScreen extends StatelessWidget {
  final String detail;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  const _BootErrorScreen({
    required this.detail,
    required this.onRetry,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF140B2E),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Color(0xFFF87171), size: 64),
                const SizedBox(height: 20),
                const Text(
                  'تعذّر تشغيل التطبيق',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'حدث خطأ أثناء تهيئة التطبيق على هذا الجهاز. جرّب إعادة '
                  'المحاولة؛ وإن تكررت فجرّب إعادة تعيين بيانات التشفير '
                  'المحلية.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.5),
                ),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    detail,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12, height: 1.4),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('إعادة المحاولة'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: onReset,
                  icon: const Icon(Icons.cleaning_services_rounded),
                  label: const Text('إعادة تعيين بيانات التشفير المحلية'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

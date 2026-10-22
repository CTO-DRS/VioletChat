import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'features/auth/violet_auth_screen.dart';
import 'features/chats/chats_screen.dart';
import 'features/settings/settings_screen.dart';
import 'routing/app_router.dart';
import 'services/device_security_service.dart';
import 'services/push_service.dart';
import 'state/app_services.dart';
import 'state/auth_controller.dart';
import 'state/chats_controller.dart';
import 'state/settings_controller.dart';
import 'theme/app_theme.dart';
import 'widgets/brand.dart';

/// Root widget: theme + global controllers + auth gate.
class VioletApp extends StatelessWidget {
  const VioletApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>();
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: AppRouter.navigatorKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: settings.themeMode,
      locale: const Locale('ar'),
      // v0.1.0: locale 'ar' was declared without any delegate — every
      // TextField crashed at build ("No MaterialLocalizations found")
      // and the login form showed as a gray ErrorWidget box on real
      // devices. These three delegates provide real Arabic Material
      // / Widgets / Cupertino localizations.
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ar'), Locale('en')],
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      onGenerateRoute: AppRouter.route,
      home: const _AuthGate(),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthController>();
    auth.addListener(_onAuthChanged);
    if (auth.signedIn && auth.me == null && !auth.booting) {
      auth.bootstrap();
    }
    _wireNotificationTaps();
  }

  /// v0.1.0: both notification paths (local realtime notifs + FCM
  /// system push) deep-link into the chat carried by their payload.
  /// Guarded — wiring must happen exactly once per process.
  static bool _tapsWired = false;
  void _wireNotificationTaps() {
    if (_tapsWired) return;
    _tapsWired = true;
    context.read<AppServices>().notifications.onMessageTap =
        (chatId) => AppRouter.openChatById(chatId);
    PushService.onOpenChat =
        (chatId) => AppRouter.openChatById(chatId);
  }

  void _onAuthChanged() {
    if (!mounted) return;
    final auth = context.read<AuthController>();
    if (auth.signedIn && auth.me != null) {
      final chats = context.read<ChatsController>();
      chats.start();
    }
    setState(() {});
  }

  @override
  void dispose() {
    context.read<AuthController>().removeListener(_onAuthChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    if (!auth.signedIn) {
      // v0.1.0 هوية Violet Chat: الشاشة الزجاجية الجديدة — تعرض
      // تلقائياً التدفق القائم عند غياب Firebase (بلا انحدار).
      return const VioletAuthScreen();
    }
    if (auth.booting) {
      return const _BootScreen();
    }
    if (auth.me == null) {
      return _BootError(
        message: auth.bootError ?? 'حدث خطأ غير متوقع',
        onRetry: () => auth.bootstrap(),
      );
    }
    // v0.1.0 device privacy: biometric gate in front of the app.
    // Opt-in (privacy settings) and fail-safe — on devices without
    // enrolled biometrics the gate never engages.
    return const _AppLockGate(child: ChatsScreen());
  }
}

/// Locks the app while `settings.appLock` is on AND the device has
/// enrolled biometrics. Cold starts always lock immediately; coming
/// back from the background locks after the configured grace window
/// (v0.1.0: settings.appLockGraceSecs — 0/60/300 s; 0 = v0.1.0
/// behaviour of locking on every backgrounding). Unlock is strictly
/// local (local_auth); no network, no server, no lockout risk.
class _AppLockGate extends StatefulWidget {
  final Widget child;
  const _AppLockGate({required this.child});

  @override
  State<_AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<_AppLockGate>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _prompting = false;

  /// When the app went to the background (null = was never away or
  /// already consumed).
  DateTime? _bgAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold start counts as "coming from background": if the lock is
    // enabled and available, require an unlock right away — the grace
    // window never applies to a fresh app start.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLock());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _bgAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_locked) {
        unawaited(_promptUnlock());
      } else {
        _maybeLock(fromBackground: true);
      }
    }
  }

  void _maybeLock({bool fromBackground = false}) {
    final settings = context.read<SettingsController>().settings;
    if (!settings.appLock || _locked) return;
    if (fromBackground) {
      final bgAt = _bgAt;
      _bgAt = null;
      if (bgAt == null) return;
      final elapsed = DateTime.now().difference(bgAt).inSeconds;
      if (elapsed < settings.appLockGraceSecs) return; // inside grace
    }
    // Fail-safe: only lock when biometrics are actually usable on
    // this device — a preference must never become a lockout.
    unawaited(DeviceSecurityService.biometricsAvailable().then((ok) {
      if (ok && mounted && !_locked) {
        setState(() => _locked = true);
        unawaited(_promptUnlock());
      }
    }));
  }

  Future<void> _promptUnlock() async {
    if (_prompting || !_locked || !mounted) return;
    _prompting = true;
    final ok = await DeviceSecurityService.authenticate();
    _prompting = false;
    if (!mounted) return;
    if (ok) {
      setState(() => _locked = false);
    }
    // On failure the gate simply stays; the user can tap retry.
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    return _LockScreen(onUnlock: () => unawaited(_promptUnlock()));
  }
}

/// Brand-consistent lock screen shown by [_AppLockGate].
class _LockScreen extends StatelessWidget {
  final VoidCallback onUnlock;
  const _LockScreen({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 72),
            const SizedBox(height: 24),
            Icon(Icons.lock_rounded, size: 44, color: cs.primary),
            const SizedBox(height: 12),
            Text('التطبيق مقفل',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('تحقق بالبصمة أو الوجه للمتابعة',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onUnlock,
              icon: const Icon(Icons.fingerprint_rounded),
              label: const Text('فتح'),
            ),
          ],
        ),
      ),
    );
  }
}

class _BootScreen extends StatelessWidget {
  const _BootScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 72),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('جاري تجهيز مفاتيح التشفير...',
                style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _BootError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 56, color: AppTheme.brandSecondary),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(
                  onPressed: onRetry, child: const Text('إعادة المحاولة')),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings screen entry referenced by the router; kept here to avoid
/// a circular import between router and settings feature.
class SettingsRoute extends StatelessWidget {
  const SettingsRoute({super.key});

  @override
  Widget build(BuildContext context) => const SettingsScreen();
}

const String appTitle = AppConfig.appName;

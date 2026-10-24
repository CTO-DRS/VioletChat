import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'features/auth/violet_auth_screen.dart';
import 'features/chats/chats_screen.dart';
import 'features/settings/settings_screen.dart';
import 'routing/app_router.dart';
import 'services/device_security_service.dart';
import 'services/pin_lock_service.dart';
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
    // v0.1.0 device privacy: biometric/PIN gate in front of the app.
    // Opt-in (privacy settings) and fail-safe — with neither a PIN set
    // nor enrolled biometrics the gate never engages.
    return const _AppLockGate(child: ChatsScreen());
  }
}

/// Locks the app while `settings.appLock` is on AND at least one
/// unlock factor exists: a device-local PIN (v0.1.14) or enrolled
/// biometrics. Cold starts always lock immediately; coming back from
/// the background locks after the configured grace window
/// (settings.appLockGraceSecs — 0/60/300 s; 0 = lock on every
/// backgrounding). Unlock is strictly local — no network, no server,
/// no lockout risk.
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
  bool _pinSet = false;
  bool _biometricsOk = false;

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
        // v0.1.14 — the PIN can appear/disappear while the gate sits
        // locked (settings lives inside the gated tree, so in practice
        // this only shifts between processes) — refresh factors cheaply.
        unawaited(_refreshFactors());
        if (_pinSet || _biometricsOk) {
          if (!_pinSet) unawaited(_promptUnlock());
        }
      } else {
        _maybeLock(fromBackground: true);
      }
    }
  }

  Future<void> _refreshFactors() async {
    _pinSet = await PinLockService.I.isPinSet();
    _biometricsOk = await DeviceSecurityService.biometricsAvailable();
    if (mounted) setState(() {});
  }

  Future<void> _maybeLock({bool fromBackground = false}) async {
    final settings = context.read<SettingsController>().settings;
    if (!settings.appLock || _locked) return;
    if (fromBackground) {
      final bgAt = _bgAt;
      _bgAt = null;
      if (bgAt == null) return;
      final elapsed = DateTime.now().difference(bgAt).inSeconds;
      if (elapsed < settings.appLockGraceSecs) return; // inside grace
    }
    // Fail-safe: only lock when at least ONE factor is actually
    // usable on this device — a preference must never become a
    // lockout. (v0.1.14: PIN counts; stored hash read is cheap.)
    _pinSet = await PinLockService.I.isPinSet();
    _biometricsOk = await DeviceSecurityService.biometricsAvailable();
    if (mounted && !_locked && (_pinSet || _biometricsOk)) {
      setState(() => _locked = true);
      // Biometric-only flow keeps the old auto-prompt behaviour; with
      // a PIN the user types (or taps the fingerprint shortcut).
      if (!_pinSet) unawaited(_promptUnlock());
    }
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

  /// v0.1.14 — PIN unlock path from the lock screen keypad.
  Future<void> _unlockWithPin(String pin) async {
    final ok = await PinLockService.I.verifyWithThrottle(pin);
    if (!mounted) return;
    if (ok) setState(() => _locked = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    return _LockScreen(
      pinSet: _pinSet,
      biometricsOk: _biometricsOk,
      onBiometric: () => _promptUnlock(),
      onPinSubmit: _unlockWithPin,
    );
  }
}

/// Brand-consistent lock screen shown by [_AppLockGate].
///
/// v0.1.14 — two unlock flows:
///  - PIN set → dot indicators + numeric keypad (auto-submit at the
///    stored length), 5 wrong entries trigger a 30 s cool-down, and a
///    fingerprint shortcut rides the keypad when biometrics exist.
///  - No PIN → the old biometric-only screen (auto-prompt + retry).
class _LockScreen extends StatefulWidget {
  final bool pinSet;
  final bool biometricsOk;
  final VoidCallback onBiometric;
  final Future<void> Function(String pin) onPinSubmit;
  const _LockScreen({
    required this.pinSet,
    required this.biometricsOk,
    required this.onBiometric,
    required this.onPinSubmit,
  });

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  String _entry = '';
  bool _wrong = false;
  bool _verifying = false;
  int? _pinLen;
  int _coolLeft = 0;
  Timer? _coolTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLen());
  }

  Future<void> _loadLen() async {
    final len = await PinLockService.I.pinLength();
    if (!mounted) return;
    setState(() => _pinLen = len ?? 4);
    _startCoolTimer();
  }

  /// Tick the cool-down counter while it is active.
  void _startCoolTimer() {
    _coolTimer?.cancel();
    _coolTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = PinLockService.I.lockoutSecsRemaining;
      if (!mounted) return;
      if (left != _coolLeft) setState(() => _coolLeft = left);
      if (left == 0) _coolTimer?.cancel();
    });
  }

  Future<void> _pressDigit(String d) async {
    if (_verifying || _coolLeft > 0) return;
    if (_entry.length >= (_pinLen ?? 6)) return;
    HapticFeedback.selectionClick();
    final next = _entry + d;
    setState(() {
      _entry = next;
      _wrong = false;
    });
    if (_pinLen != null && next.length == _pinLen) {
      setState(() => _verifying = true);
      await widget.onPinSubmit(next);
      if (!mounted) return;
      // Wrong pin (or cool-down just started) → wipe + feedback.
      final locked = PinLockService.I.lockedOut;
      setState(() {
        _verifying = false;
        _entry = '';
        _wrong = !locked; // success path already unlocked the gate
        _coolLeft = PinLockService.I.lockoutSecsRemaining;
      });
      if (_coolLeft > 0) _startCoolTimer();
      if (locked) HapticFeedback.heavyImpact();
    }
  }

  @override
  void dispose() {
    _coolTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!widget.pinSet) {
      // Biometric-only (pre-v0.1.14 flow).
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
                onPressed: widget.onBiometric,
                icon: const Icon(Icons.fingerprint_rounded),
                label: const Text('فتح'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const BrandLogo(size: 64),
                const SizedBox(height: 20),
                Icon(Icons.lock_rounded, size: 40, color: cs.primary),
                const SizedBox(height: 10),
                Text('التطبيق مقفل',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _coolLeft > 0
                      ? 'محاولات كثيرة — انتظر $_coolLeft ثانية'
                      : 'أدخل رمز القفل للمتابعة',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _coolLeft > 0
                          ? AppTheme.errorColor
                          : cs.onSurfaceVariant),
                ),
                const SizedBox(height: 22),
                // Dot indicators (RTL-safe: order is symmetric).
                SizedBox(
                  height: 22,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < (_pinLen ?? 4); i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          width: _wrong ? 14 : 12,
                          height: _wrong ? 14 : 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: i < _entry.length
                                ? (_wrong
                                    ? AppTheme.errorColor
                                    : cs.primary)
                                : Colors.transparent,
                            border: Border.all(
                              color: _wrong
                                  ? AppTheme.errorColor
                                  : cs.primary,
                              width: 1.6,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                _pinPad(cs),
                if (widget.biometricsOk) ...[
                  const SizedBox(height: 14),
                  TextButton.icon(
                    onPressed: widget.onBiometric,
                    icon: const Icon(Icons.fingerprint_rounded, size: 22),
                    label: const Text('استخدم البصمة'),
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _pinPad(ColorScheme cs) {
    Widget key(String label, {IconData? icon, VoidCallback? onTap}) {
      final disabled = _coolLeft > 0 || _verifying;
      return SizedBox(
        width: 72,
        height: 60,
        child: TextButton(
          onPressed: disabled ? null : (onTap ?? () => _pressDigit(label)),
          style: TextButton.styleFrom(
            shape:
                const CircleBorder(side: BorderSide(width: 0.6)),
            foregroundColor: cs.onSurface,
          ),
          child: icon != null
              ? Icon(icon, size: 24, color: AppTheme.brandSecondary)
              : Text(label,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w600)),
        ),
      );
    }

    return Column(
      children: [
        for (final row in [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [for (final d in row) key(d)],
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Biometric shortcut when enrolled (mirrors the big
            // messengers' keypad layout).
            widget.biometricsOk
                ? key('', icon: Icons.fingerprint_rounded,
                    onTap: widget.onBiometric)
                : const SizedBox(width: 72, height: 60),
            key('0'),
            key('', icon: Icons.backspace_outlined, onTap: _backspace),
          ],
        ),
      ],
    );
  }

  void _backspace() {
    if (_entry.isEmpty || _verifying) return;
    HapticFeedback.selectionClick();
    setState(() {
      _entry = _entry.substring(0, _entry.length - 1);
      _wrong = false;
    });
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

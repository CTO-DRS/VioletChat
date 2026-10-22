import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../services/violet_auth_service.dart';
import '../../state/violet_auth_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';
import 'auth_screen.dart';

/// شاشة هوية Violet Chat — «Violet Glass»:
/// خلفية بنفسجية داكنة فاخرة + بطاقة زجاجية متموّجة باعتدال
/// (بلور محدود ليبقى الأداء جيداً على الأجهزة الاقتصادية)،
/// حقول متناسقة، حالات تحميل/خطأ/نجاح صريحة، RTL كامل.
///
/// عند غياب Firebase (غير مهيأ) تعرض الشاشة تدفق الحساب القائم
/// كما هو — لا انحدار وظيفي أبداً.
class VioletAuthScreen extends StatelessWidget {
  const VioletAuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final violet = context.watch<VioletAuthController>();
    if (!violet.violet.available) {
      // Firebase غير مهيأ — الشاشة القائمة حرفياً (سلوك مثبت).
      return const AuthScreen();
    }
    return const _VioletGlassScaffold(child: _VioletAuthForm());
  }
}

// -------------------------------------------------------------------
// الهيكل الزجاجي
// -------------------------------------------------------------------
class _VioletGlassScaffold extends StatelessWidget {
  final Widget child;
  const _VioletGlassScaffold({required this.child});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0A0512), Color(0xFF150B2E), Color(0xFF1D0F3E)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            // هالات بنفسجية ناعمة — عمق بلا تشتيت (RTL-aware).
            const PositionedDirectional(
              top: -120,
              end: -80,
              child: _GlowOrb(size: 280, color: Color(0xFF7C3AED)),
            ),
            const PositionedDirectional(
              bottom: -140,
              start: -100,
              child: _GlowOrb(size: 320, color: Color(0xFF4C1D95)),
            ),
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: BackdropFilter(
                        // بلور معتدل: زجاجية واضحة دون كلفة مفرطة.
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B1038).withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(28),
                            border: Border.all(
                              color: const Color(0xFF8B5CF6).withValues(alpha: 0.28),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF7C3AED)
                                    .withValues(alpha: 0.18),
                                blurRadius: 40,
                                offset: const Offset(0, 18),
                              ),
                            ],
                          ),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  final double size;
  final Color color;
  const _GlowOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.30), color.withValues(alpha: 0.0)],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------
// النموذج
// -------------------------------------------------------------------
enum _VioletMode { login, signup, forgot }

class _VioletAuthForm extends StatefulWidget {
  const _VioletAuthForm();

  @override
  State<_VioletAuthForm> createState() => _VioletAuthFormState();
}

class _VioletAuthFormState extends State<_VioletAuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  _VioletMode _mode = _VioletMode.login;
  bool _hidePassword = true;
  bool _resetSent = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    final ctl = context.read<VioletAuthController>();
    final messenger = ScaffoldMessenger.of(context);

    final email = _email.text.trim();
    final pass = _password.text;
    bool ok = false;
    switch (_mode) {
      case _VioletMode.login:
        ok = await ctl.violetSignIn(email, pass);
      case _VioletMode.signup:
        ok = await ctl.violetSignUp(
          displayName: _name.text,
          email: email,
          password: pass,
        );
      case _VioletMode.forgot:
        ok = await ctl.sendVioletReset(email);
        if (ok) setState(() => _resetSent = true);
    }

    // البوابة تنتقل تلقائياً عند اكتمال التمهيد — هنا فقط رسائل الحالة.
    final (err, info) = ctl.consumeMessages();
    if (err != null) {
      messenger.showSnackBar(SnackBar(content: Text(err)));
    } else if (info != null && _mode != _VioletMode.forgot) {
      messenger.showSnackBar(SnackBar(content: Text(info)));
    }
    if (ok && mounted && _mode == _VioletMode.forgot) {
      setState(() {});
    }
  }

  String? _validateEmail(String? v) => VioletValidators.email(v);

  String? _validatePassword(String? v) => VioletValidators.password(v);

  Future<void> _googleSignIn() async {
    FocusScope.of(context).unfocus();
    final ctl = context.read<VioletAuthController>();
    final messenger = ScaffoldMessenger.of(context);

    final ok = await ctl.violetGoogleSignIn();

    // البوابة تنتقل تلقائياً عند اكتمال التمهيد — هنا فقط رسائل الحالة
    // (الإلغاء صامت: لا snackbar إطلاقاً).
    final (err, info) = ctl.consumeMessages();
    if (err != null) {
      messenger.showSnackBar(SnackBar(
        content: Text(err),
        duration: const Duration(seconds: 5),
      ));
    } else if (ok && info != null) {
      messenger.showSnackBar(SnackBar(content: Text(info)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<VioletAuthController>();
    final busy = ctl.busy;
    final dim = Theme.of(context).textTheme.bodyMedium;

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: BrandLogo(size: 76)),
          const SizedBox(height: 14),
          Text(
            AppConfig.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(letterSpacing: 1.1),
          ),
          const SizedBox(height: 4),
          Text(
            AppConfig.appNameAr,
            textAlign: TextAlign.center,
            style: dim?.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 22),

          // تبويبات الدخول/الإنشاء — الاستعادة تُفتح من «نسيت كلمة المرور».
          if (_mode != _VioletMode.forgot) ...[
            SegmentedButton<_VioletMode>(
              segments: const [
                ButtonSegment(
                  value: _VioletMode.login,
                  icon: Icon(Icons.login_rounded, size: 18),
                  label: Text('تسجيل الدخول'),
                ),
                ButtonSegment(
                  value: _VioletMode.signup,
                  icon: Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: Text('حساب جديد'),
                ),
              ],
              selected: {_mode == _VioletMode.forgot ? _VioletMode.login : _mode},
              showSelectedIcon: false,
              onSelectionChanged: busy
                  ? null
                  : (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 18),
          ] else ...[
            Row(
              textDirection: TextDirection.rtl,
              children: [
                IconButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          _mode = _VioletMode.login;
                          _resetSent = false;
                        }),
                  icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                ),
                Text('استعادة كلمة المرور',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
          ],

          if (_resetSent && _mode == _VioletMode.forgot)
            _InfoCard(
              icon: Icons.mark_email_read_outlined,
              color: AppTheme.successColor,
              text: 'أُرسل الرابط إلى بريدك — افتح الرسالة ثم عد هنا '
                  'وسجّل الدخول بكلمة المرور الجديدة.',
            )
          else ...[
            // الاسم (إنشاء فقط) — نمو/انكماش سلس.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _mode == _VioletMode.signup
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 13),
                      child: TextFormField(
                        controller: _name,
                        enabled: !busy,
                        textDirection: TextDirection.rtl,
                        autofillHints: const [AutofillHints.name],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'الاسم الظاهر',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        validator: VioletValidators.displayName,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),

            TextFormField(
              controller: _email,
              enabled: !busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              textInputAction:
                  _mode == _VioletMode.forgot ? TextInputAction.done : TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'البريد الإلكتروني',
                prefixIcon: Icon(Icons.mail_outline_rounded),
              ),
              validator: _validateEmail,
            ),
            const SizedBox(height: 13),

            if (_mode != _VioletMode.forgot)
              TextFormField(
                controller: _password,
                enabled: !busy,
                obscureText: _hidePassword,
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => busy ? null : _submit(),
                decoration: InputDecoration(
                  labelText: 'كلمة المرور',
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => _hidePassword = !_hidePassword),
                    icon: Icon(_hidePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined),
                  ),
                ),
                validator: _validatePassword,
              ),

            if (_mode == _VioletMode.login)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  onPressed:
                      busy ? null : () => setState(() => _mode = _VioletMode.forgot),
                  child: const Text('نسيت كلمة المرور؟'),
                ),
              ),
            const SizedBox(height: 6),

            FilledButton(
              onPressed: busy ? null : _submit,
              child: busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.4, color: Colors.white),
                    )
                  : Text(switch (_mode) {
                      _VioletMode.login => 'دخول',
                      _VioletMode.signup => 'إنشاء الحساب',
                      _VioletMode.forgot => 'إرسال رابط الاستعادة',
                    }),
            ),

            // زر Google (v0.1.1) — خفي في وضع الاستعادة (لا معنى له).
            if (_mode != _VioletMode.forgot) ...[
              const SizedBox(height: 12),
              _GoogleGlassButton(
                onPressed: busy ? null : _googleSignIn,
                busy: busy,
              ),
            ],
          ],

          const SizedBox(height: 18),

          // مسار الحساب القائم — يحفظ وصول مستخدمي الإصدارات السابقة.
          Row(
            children: [
              const Expanded(
                  child: Divider(color: Colors.white24, thickness: 0.8)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('أو',
                    style: dim?.copyWith(fontSize: 12)),
              ),
              const Expanded(
                  child: Divider(color: Colors.white24, thickness: 0.8)),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: busy ? null : _openLegacy,
            icon: const Icon(Icons.key_rounded, size: 18),
            label: const Text('الدخول بحساب مراسلة قائم'),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white38),
              foregroundColor: Colors.white.withValues(alpha: 0.92),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 16),

          Row(
            textDirection: TextDirection.rtl,
            children: [
              const Icon(Icons.verified_user_rounded,
                  size: 15, color: AppTheme.brandSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'رسائلك مشفرة طرف-لطرف، وبيانات اعتمادك تديرها '
                  'Firebase Authentication ولا تُخزّن في التطبيق',
                  textAlign: TextAlign.right,
                  style: dim?.copyWith(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openLegacy() async {
    final ctl = context.read<VioletAuthController>();
    final authCtl = ctl.auth;
    // الخروج من جلسة Firebase إن وُجدت (المستخدم اختار المسار القائم).
    if (ctl.violetSession != null) {
      try {
        await ctl.violet.signOut();
      } catch (_) {}
    }
    if (!mounted) return;

    // بعد نجاح الدخول القائم تتحول بوابة التطبيق تلقائياً للمحادثات —
    // نغلق هذه الشاشة المفتوحة فوقها بمجرد تثبت الجلسة.
    void listener() {
      if (authCtl.signedIn && mounted) {
        final nav = Navigator.of(context);
        if (nav.canPop()) nav.pop();
      }
    }

    authCtl.addListener(listener);
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
    authCtl.removeListener(listener);
  }
}

/// بطاقة معلومات نجاح/تنبيه داخل الزجاج.
class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _InfoCard(
      {required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------
// زر Google (v0.1.1) — أبيض زجاجي بشعار G الرسمي بأربعة ألوان.
// الشعار مرسوم برمجياً (CustomPaint) بلا أي أصول خارجية — المسارات
// هي المسارات الرسمية لشعار Google G على شبكة 48×48.
// -------------------------------------------------------------------
class _GoogleGlassButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;
  const _GoogleGlassButton({required this.onPressed, required this.busy});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white.withValues(alpha: 0.97),
          foregroundColor: const Color(0xFF1F2937),
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.55),
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.65)),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const SizedBox(
                width: 19,
                height: 19,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            else
              const CustomPaint(
                size: Size(19, 19),
                painter: _GoogleGPainter(),
              ),
            const SizedBox(width: 11),
            const Text(
              'المتابعة عبر Google',
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2937),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// شعار Google G بأربعة ألوان — مسارات رسمية على شبكة 48×48،
/// مع محلل مسارات SVG محدود (M/L/H/V/C/S/Q/Z مطلق ونسبي) يغطي
/// المسارات الأربعة دون أي حزمة خارجية.
class _GoogleGPainter extends CustomPainter {
  const _GoogleGPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 48.0, sy = size.height / 48.0;
    final m = Matrix4.identity()..scale(sx, sy, 1.0);

    void paintPath(String d, Color color) {
      canvas.drawPath(
        _parsePath(d).transform(m.storage),
        Paint()..color = color,
      );
    }

    // الأزرق: الذراع اليمنى للحرف G.
    paintPath(
      'M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 '
      '5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z',
      _blue,
    );
    // الأخضر: الجزء السفلي.
    paintPath(
      'M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 '
      '2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 '
      '15.4 46 24 46z',
      _green,
    );
    // الأصفر: الجزء الأيسر.
    paintPath(
      'M11.69 28.18C11.25 26.86 11 25.45 11 24s.25-2.86.69-4.18v-5.7H4.34'
      'C2.85 17.09 2 20.45 2 24c0 3.55.85 6.91 2.34 9.88l7.35-5.7z',
      _yellow,
    );
    // الأحمر: الجزء العلوي.
    paintPath(
      'M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 '
      '24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 '
      '12.31-9.07z',
      _red,
    );
  }

  static Path _parsePath(String d) {
    final path = Path();
    final cmdRe = RegExp(r'([MmLvVhHcCsSqQzZ])([^MmLvVhHcCsSqQzZ]*)');
    final numRe = RegExp(r'-?\d*\.?\d+(?:e-?\d+)?');
    double cx = 0, cy = 0, lastCx = 0, lastCy = 0;

    for (final m in cmdRe.allMatches(d)) {
      final cmd = m.group(1)!;
      final nums = numRe
          .allMatches(m.group(2)!)
          .map((n) => double.parse(n.group(0)!))
          .toList(growable: false);
      var i = 0;
      switch (cmd) {
        case 'M':
          if (nums.length >= 2) {
            cx = nums[0];
            cy = nums[1];
            path.moveTo(cx, cy);
            i = 2;
          }
          while (i + 1 < nums.length) {
            cx = nums[i];
            cy = nums[i + 1];
            path.lineTo(cx, cy);
            i += 2;
          }
        case 'm':
          if (nums.length >= 2) {
            cx += nums[0];
            cy += nums[1];
            path.moveTo(cx, cy);
            i = 2;
          }
          while (i + 1 < nums.length) {
            cx += nums[i];
            cy += nums[i + 1];
            path.lineTo(cx, cy);
            i += 2;
          }
        case 'L':
          while (i + 1 < nums.length) {
            cx = nums[i];
            cy = nums[i + 1];
            path.lineTo(cx, cy);
            i += 2;
          }
        case 'l':
          while (i + 1 < nums.length) {
            cx += nums[i];
            cy += nums[i + 1];
            path.lineTo(cx, cy);
            i += 2;
          }
        case 'H':
          if (nums.isNotEmpty) {
            cx = nums[0];
            path.lineTo(cx, cy);
          }
        case 'h':
          if (nums.isNotEmpty) {
            cx += nums[0];
            path.lineTo(cx, cy);
          }
        case 'V':
          if (nums.isNotEmpty) {
            cy = nums[0];
            path.lineTo(cx, cy);
          }
        case 'v':
          if (nums.isNotEmpty) {
            cy += nums[0];
            path.lineTo(cx, cy);
          }
        case 'C':
          while (i + 5 < nums.length) {
            path.cubicTo(nums[i], nums[i + 1], nums[i + 2], nums[i + 3],
                nums[i + 4], nums[i + 5]);
            lastCx = nums[i + 2];
            lastCy = nums[i + 3];
            cx = nums[i + 4];
            cy = nums[i + 5];
            i += 6;
          }
        case 'c':
          while (i + 5 < nums.length) {
            path.cubicTo(cx + nums[i], cy + nums[i + 1], cx + nums[i + 2],
                cy + nums[i + 3], cx + nums[i + 4], cy + nums[i + 5]);
            lastCx = cx + nums[i + 2];
            lastCy = cy + nums[i + 3];
            cx += nums[i + 4];
            cy += nums[i + 5];
            i += 6;
          }
        case 'S':
          while (i + 3 < nums.length) {
            final x2 = nums[i], y2 = nums[i + 1];
            final x = nums[i + 2], y = nums[i + 3];
            path.cubicTo(2 * cx - lastCx, 2 * cy - lastCy, x2, y2, x, y);
            lastCx = x2;
            lastCy = y2;
            cx = x;
            cy = y;
            i += 4;
          }
        case 's':
          while (i + 3 < nums.length) {
            final x2 = cx + nums[i], y2 = cy + nums[i + 1];
            final x = cx + nums[i + 2], y = cy + nums[i + 3];
            path.cubicTo(2 * cx - lastCx, 2 * cy - lastCy, x2, y2, x, y);
            lastCx = x2;
            lastCy = y2;
            cx = x;
            cy = y;
            i += 4;
          }
        case 'Q':
          if (i + 3 < nums.length) {
            path.quadraticBezierTo(
                nums[i], nums[i + 1], nums[i + 2], nums[i + 3]);
            cx = nums[i + 2];
            cy = nums[i + 3];
          }
        case 'q':
          if (i + 3 < nums.length) {
            path.quadraticBezierTo(cx + nums[i], cy + nums[i + 1],
                cx + nums[i + 2], cy + nums[i + 3]);
            cx += nums[i + 2];
            cy += nums[i + 3];
          }
        case 'Z':
        case 'z':
          path.close();
      }
    }
    return path;
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

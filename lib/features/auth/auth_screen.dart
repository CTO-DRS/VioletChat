import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/config/app_config.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// Entry screen: login / signup (RTL, Arabic).
///
/// After a successful sign-in the AuthGate in lib/app.dart reacts to
/// AuthController notifications — this screen never navigates manually.
class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: const _AuthForm(),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AuthMode { login, signup }

class _AuthForm extends StatefulWidget {
  const _AuthForm();

  @override
  State<_AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<_AuthForm> {
  static final RegExp _emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');

  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();

  _AuthMode _mode = _AuthMode.login;
  bool _busy = false;
  bool _hidePassword = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _username.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Validation
  // ------------------------------------------------------------------
  String? _validateEmail(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'أدخل البريد الإلكتروني';
    if (!_emailRe.hasMatch(value)) return 'صيغة البريد الإلكتروني غير صحيحة';
    return null;
  }

  String? _validatePassword(String? v) {
    if ((v ?? '').length < 8) return 'كلمة المرور 8 أحرف على الأقل';
    return null;
  }

  String? _validateUsername(String? v) {
    final value = (v ?? '').trim();
    if (value.length < 3) return 'اسم المستخدم 3 أحرف على الأقل';
    return null;
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------
  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_mode == _AuthMode.login) {
        await auth.signIn(_email.text.trim(), _password.text);
        // AuthGate ينتقل تلقائياً بمجرد اكتمال التجهيز
        await auth.bootstrap();
      } else {
        await auth.signUp(
            _email.text.trim(), _password.text, _username.text.trim());
        if (auth.signedIn) {
          await auth.bootstrap();
        } else {
          messenger.showSnackBar(const SnackBar(
            content:
                Text('تم إنشاء الحساب — أكّد بريدك الإلكتروني ثم سجّل الدخول'),
          ));
        }
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final emailCtrl = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('استعادة كلمة المرور'),
        content: TextField(
          controller: emailCtrl,
          keyboardType: TextInputType.emailAddress,
          textDirection: TextDirection.rtl,
          decoration: const InputDecoration(
            labelText: 'البريد الإلكتروني',
            prefixIcon: Icon(Icons.mail_outline_rounded),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, emailCtrl.text.trim()),
            child: const Text('إرسال الرابط'),
          ),
        ],
      ),
    );
    if (!mounted || email == null) return;
    if (!_emailRe.hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('أدخل بريداً إلكترونياً صحيحاً أولاً'),
      ));
      return;
    }
    final auth = context.read<AuthController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await auth.services.auth.resetPassword(email);
      messenger.showSnackBar(const SnackBar(
        content: Text('تم إرسال رابط استعادة كلمة المرور إلى بريدك'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_errorText(e))));
    }
  }

  String _errorText(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('invalid login credentials')) {
      return 'البريد الإلكتروني أو كلمة المرور غير صحيحة';
    }
    if (s.contains('already registered') ||
        s.contains('already been registered')) {
      return 'هذا البريد مسجّل مسبقاً — جرّب تسجيل الدخول';
    }
    if (s.contains('not confirmed')) {
      return 'لم يتم تأكيد البريد الإلكتروني بعد — تحقق من بريدك';
    }
    if (s.contains('rate limit')) {
      return 'محاولات كثيرة — انتظر قليلاً ثم أعد المحاولة';
    }
    if (s.contains('username')) {
      return 'اسم المستخدم غير متاح أو غير صالح';
    }
    if (s.contains('socket') ||
        s.contains('network') ||
        s.contains('failed host') ||
        s.contains('timeout')) {
      return 'تعذر الاتصال بالخادم — تحقق من الإنترنت';
    }
    return 'تعذر إكمال العملية — تحقق من البيانات والاتصال';
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          const Center(child: BrandLogo(size: 88)),
          const SizedBox(height: 20),
          Text(
            AppConfig.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .headlineMedium
                ?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 8),
          Text(
            AppConfig.appTagline,
            textAlign: TextAlign.center,
            style: dim,
          ),
          const SizedBox(height: 28),

          // Login / Signup segments
          SegmentedButton<_AuthMode>(
            segments: const [
              ButtonSegment(
                value: _AuthMode.login,
                icon: Icon(Icons.login_rounded, size: 18),
                label: Text('تسجيل الدخول'),
              ),
              ButtonSegment(
                value: _AuthMode.signup,
                icon: Icon(Icons.person_add_alt_1_rounded, size: 18),
                label: Text('حساب جديد'),
              ),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: _busy
                ? null
                : (selection) => setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 20),

          // Email
          TextFormField(
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            textDirection: TextDirection.rtl,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'البريد الإلكتروني',
              prefixIcon: Icon(Icons.mail_outline_rounded),
            ),
            validator: _validateEmail,
          ),
          const SizedBox(height: 14),

          // Username (signup only) — smooth grow/shrink
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _mode == _AuthMode.signup
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: TextFormField(
                      controller: _username,
                      enabled: !_busy,
                      textDirection: TextDirection.rtl,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: 'اسم المستخدم',
                        prefixIcon: Icon(Icons.alternate_email_rounded),
                      ),
                      validator: _validateUsername,
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),

          // Password
          TextFormField(
            controller: _password,
            enabled: !_busy,
            obscureText: _hidePassword,
            textDirection: TextDirection.rtl,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'كلمة المرور',
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(
                onPressed: () => setState(() => _hidePassword = !_hidePassword),
                icon: Icon(_hidePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              ),
            ),
            validator: _validatePassword,
            onFieldSubmitted: (_) {
              if (!_busy) _submit();
            },
          ),
          const SizedBox(height: 8),

          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed:
                  _busy || _mode != _AuthMode.login ? null : _forgotPassword,
              child: const Text('نسيت كلمة المرور؟'),
            ),
          ),
          const SizedBox(height: 12),

          // Submit
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: Colors.white),
                  )
                : Text(_mode == _AuthMode.login ? 'دخول' : 'إنشاء الحساب'),
          ),
          const SizedBox(height: 24),

          // Security footer
          Row(
            textDirection: TextDirection.rtl,
            children: [
              const Icon(Icons.verified_user_rounded,
                  size: 15, color: AppTheme.brandSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'جميع الرسائل مشفرة طرف-لطرف — لا يستطيع أي طرف آخر قراءتها',
                  textAlign: TextAlign.right,
                  style: dim?.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

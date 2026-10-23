import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/models.dart';
import '../../services/qr_add_service.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../state/chats_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';
import '../../widgets/verified_badge.dart';

/// الملف الشخصي — شاشة كاملة (v0.1.0):
/// الصورة الشخصية (تغيير/إزالة)، الاسم المعروض، اسم المستخدم، النبذة،
/// البريد الإلكتروني (عرض + تغيير)، كلمة المرور، وتاريخ الانضمام.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _busy = false;

  AuthController get _auth => context.read<AuthController>();
  AppServices get _services => context.read<AppServices>();

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  String _errText(Object e) {
    if (e is AppException) return e.message;
    if (e is AuthException) {
      if (e.code == 'over_email_send_rate_limit' || e.statusCode == '429') {
        return 'تم تجاوز حد إرسال البريد — أعد المحاولة بعد نحو ساعة';
      }
      if (e.code == 'invalid_credentials' || e.statusCode == '400') {
        return 'بيانات غير صحيحة — تحقق وأعد المحاولة';
      }
      if (e.code == 'weak_password' || e.statusCode == '422') {
        return 'كلمة المرور ضعيفة — استخدم 8 أحرف على الأقل مع أرقام';
      }
      return e.message.isNotEmpty ? e.message : 'تعذر إكمال العملية';
    }
    return 'تعذر إكمال العملية — أعد المحاولة';
  }

  Future<void> _guard(Future<void> Function() op) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await op();
    } catch (e) {
      _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===================================================================
  // Text fields (name / username / bio)
  // ===================================================================
  Future<void> _editField({
    required String title,
    required String initial,
    required int maxLines,
    required int maxLength,
    String? hint,
    String? helper,
    TextInputType? keyboardType,
    String? Function(String)? validate,
    required Future<void> Function(String value) save,
  }) async {
    final controller = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: maxLines,
              maxLength: maxLength,
              keyboardType: keyboardType,
              decoration: InputDecoration(
                hintText: hint ?? title,
                helperText: helper,
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حفظ')),
        ],
      ),
    );
    if (ok != true) return;
    final value = controller.text.trim();
    controller.dispose();
    if (value == initial.trim()) return;
    if (validate != null) {
      final err = validate(value);
      if (err != null) {
        _snack(err);
        return;
      }
    }
    await _guard(() async {
      await save(value);
      await _auth.refreshProfile();
      _snack('تم الحفظ');
    });
  }

  Future<void> _editDisplayName(String current) => _editField(
        title: 'الاسم المعروض',
        initial: current,
        maxLines: 1,
        maxLength: 40,
        save: (v) async {
          if (v.isEmpty) {
            throw const AppException('validation', 'الاسم لا يمكن أن يكون فارغاً');
          }
          await _services.profiles.updateMyProfile(displayName: v);
        },
      );

  Future<void> _editBio(String current) => _editField(
        title: 'نبذة',
        initial: current,
        maxLines: 3,
        maxLength: 160,
        hint: 'أضف نبذة قصيرة عنك',
        save: (v) => _services.profiles.updateMyProfile(bio: v),
      );

  Future<void> _editUsername(String current) => _editField(
        title: 'اسم المستخدم',
        initial: current,
        maxLines: 1,
        maxLength: 20,
        helper: '3-20 حرفاً إنجليزياً أو أرقام أو شرطة سفلية _',
        keyboardType: TextInputType.text,
        save: (v) => _services.profiles.updateUsername(v),
      );

  // ===================================================================
  // v0.1.9 — رمز QR الشخصي + مشاركته
  // ===================================================================
  void _showMyQr(String username) {
    final payload = QrAddService.buildPayload(username);
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('رمز الإضافة الخاص بي',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(
                data: payload,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF3B1E54)),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF3B1E54)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '@$username',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.brandSecondary),
            ),
            const SizedBox(height: 4),
            Text(
              'من جهاز صديق: محادثة جديدة ← إضافة بمسح رمز QR',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Theme.of(dlgCtx).textTheme.bodyMedium?.color),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('إغلاق'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dlgCtx);
              Share.share(
                  'أضفني على Violet Chat — رمزي: $payload');
            },
            icon: const Icon(Icons.share_outlined, size: 18),
            label: const Text('مشاركة'),
          ),
        ],
      ),
    );
  }

  // ===================================================================
  // Avatar (v0.1.0)
  // ===================================================================
  Future<void> _avatarSheet(String? currentPath) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined,
                  color: AppTheme.brandPrimary),
              title: const Text('اختيار من المعرض'),
              onTap: () => Navigator.pop(ctx, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined,
                  color: AppTheme.brandPrimary),
              title: const Text('التقاط بالكاميرا'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
            if (currentPath != null && currentPath.isNotEmpty)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: AppTheme.errorColor),
                title: const Text('إزالة الصورة',
                    style: TextStyle(color: AppTheme.errorColor)),
                onTap: () => Navigator.pop(ctx, 'remove'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null) return;
    if (choice == 'remove') {
      await _guard(() async {
        await _services.profiles.removeAvatar();
        await _auth.refreshProfile();
        _snack('تمت إزالة الصورة');
      });
      return;
    }
    await _pickProcessUpload(
        choice == 'camera' ? ImageSource.camera : ImageSource.gallery);
  }

  /// Pick -> center square crop -> 512px -> JPEG -> upload -> refresh.
  Future<void> _pickProcessUpload(ImageSource source) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 92,
      );
      if (picked == null) return;
      if (!mounted) return;
      setState(() => _busy = true);
      final raw = await picked.readAsBytes();
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        _snack('تعذر قراءة الصورة — جرّب صورة أخرى');
        return;
      }
      final side = min(decoded.width, decoded.height);
      final cropped = img.copyCrop(
        decoded,
        x: (decoded.width - side) ~/ 2,
        y: (decoded.height - side) ~/ 2,
        width: side,
        height: side,
      );
      final resized = img.copyResize(
        cropped,
        width: 512,
        height: 512,
        interpolation: img.Interpolation.average,
      );
      final jpeg = Uint8List.fromList(img.encodeJpg(resized, quality: 86));
      await _services.profiles.uploadAvatar(jpeg);
      await _auth.refreshProfile();
      _snack('تم تحديث الصورة الشخصية');
    } catch (e) {
      _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===================================================================
  // Account — email (v0.1.0)
  // ===================================================================
  Future<void> _changeEmail(String currentEmail) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تغيير البريد الإلكتروني'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('البريد الحالي: $currentEmail',
                style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'البريد الجديد',
                helperText:
                    'سيصلك رابط تأكيد على البريد الجديد لتفعيل التغيير',
                counterText: '',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('إرسال رابط التأكيد')),
        ],
      ),
    );
    if (ok != true) return;
    final newEmail = controller.text.trim();
    controller.dispose();
    if (newEmail == currentEmail) return;
    if (!newEmail.contains('@') || newEmail.length < 5) {
      _snack('أدخل بريداً إلكترونياً صحيحاً');
      return;
    }
    await _guard(() async {
      await _services.profiles.changeEmail(newEmail);
      _snack('أُرسل رابط التأكيد إلى $newEmail — فعّل التغيير من بريدك');
    });
  }

  // ===================================================================
  // Account — password (v0.1.0)
  // Verify the CURRENT password by re-authenticating, then update.
  // ===================================================================
  Future<void> _changePassword() async {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تغيير كلمة المرور'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentCtrl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'كلمة المرور الحالية'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'كلمة المرور الجديدة',
                helperText: '8 أحرف على الأقل',
                counterText: '',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmCtrl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'تأكيد كلمة المرور الجديدة'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('تغيير')),
        ],
      ),
    );
    if (ok != true) {
      currentCtrl.dispose();
      newCtrl.dispose();
      confirmCtrl.dispose();
      return;
    }
    final current = currentCtrl.text;
    final next = newCtrl.text;
    final confirm = confirmCtrl.text;
    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
    if (next.length < 8) {
      _snack('كلمة المرور الجديدة: 8 أحرف على الأقل');
      return;
    }
    if (next != confirm) {
      _snack('تأكيد كلمة المرور غير مطابق');
      return;
    }
    final email = _services.auth.email;
    if (email == null || email.isEmpty) {
      _snack('تعذر التحقق — سجّل الدخول من جديد');
      return;
    }
    await _guard(() async {
      // Re-auth first — proves this device's user knows the current
      // password; a wrong answer never reaches the update call.
      await _services.client.auth
          .signInWithPassword(email: email, password: current);
      await _services.profiles.changePassword(next);
      _snack('تم تغيير كلمة المرور');
    });
  }

  // ===================================================================
  // v0.1.2 — stats row (mockup «152 / 1.2K / 48»): real local data only.
  // ===================================================================
  /// Starred rows count from the server — 0 on any error (decorative).
  Future<int> _starredCount() async {
    try {
      final res = await _services.client.rpc('get_starred_messages') as List;
      return res.length;
    } catch (_) {
      return 0;
    }
  }

  int _daysWithUs(Profile me) {
    try {
      final joined = DateTime.parse(me.createdAt).toLocal();
      final days = DateTime.now().difference(joined).inDays;
      return days < 0 ? 0 : days;
    } catch (_) {
      return 0;
    }
  }

  // ===================================================================
  // Build
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    final me = context.watch<AuthController>().me;
    if (me == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final email = _services.auth.email ?? '—';

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('الملف الشخصي'),
        ),
        body: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // ---------------- avatar ----------------
                Center(
                  child: Stack(
                    children: [
                      Hero(
                        tag: 'profile-${me.id}',
                        child: AvatarWidget(profile: me, radius: 52),
                      ),
                      Positioned.directional(
                        textDirection: TextDirection.rtl,
                        bottom: 0,
                        end: 0,
                        child: Material(
                          color: AppTheme.brandPrimary,
                          shape: const CircleBorder(),
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: _busy ? null : () => _avatarSheet(me.avatarPath),
                            child: const SizedBox(
                              width: 34,
                              height: 34,
                              child: Icon(Icons.photo_camera,
                                  size: 19, color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Center(
                  // v0.1.1: verification badge + admin chip on my header
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(me.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge),
                      ),
                      if (me.isVerified) ...[
                        const SizedBox(width: 4),
                        const VerifiedBadge(size: 20),
                      ],
                      if (me.isPlatformAdmin) ...[
                        const SizedBox(width: 6),
                        const AdminChip(fontSize: 11),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Center(
                  child: Text('@${me.username}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.brandSecondary)),
                ),
                const SizedBox(height: 18),

                // v0.1.2 — stats strip: المحادثات / المحفوظة / أيام معنا
                _NexStatsCard(
                  chats: context.watch<ChatsController>().chats.length,
                  starredFuture: _starredCount(),
                  days: _daysWithUs(me),
                ),
                const SizedBox(height: 20),

                // ---------------- profile fields ----------------
                _sectionLabel('بياناتي'),
                _Tile(
                  icon: Icons.badge_outlined,
                  title: 'الاسم المعروض',
                  subtitle:
                      me.displayName.isEmpty ? 'غير محدد' : me.displayName,
                  onTap: () => _editDisplayName(me.displayName),
                ),
                _Tile(
                  icon: Icons.alternate_email,
                  title: 'اسم المستخدم',
                  subtitle: '@${me.username}',
                  onTap: () => _editUsername(me.username),
                ),
                // v0.1.9 — رمز QR الشخصي: جهاز آخر يمسحه من «محادثة جديدة»
                // فيفتح محادثتك فوراً بلا بحث يدوي.
                _Tile(
                  icon: Icons.qr_code_2_rounded,
                  title: 'رمز QR الخاص بي',
                  subtitle: 'اعرضه لصديق ليمسحه ويضيفك فوراً',
                  onTap: () => _showMyQr(me.username),
                ),
                _Tile(
                  icon: Icons.notes_outlined,
                  title: 'نبذة',
                  subtitle: (me.bio == null || me.bio!.isEmpty)
                      ? 'أضف نبذة قصيرة عنك'
                      : me.bio!,
                  onTap: () => _editBio(me.bio ?? ''),
                ),

                _sectionLabel('الحساب'),
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.email_outlined,
                            color: AppTheme.brandPrimary),
                        title: const Text('البريد الإلكتروني',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(email,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: () => _changeEmail(email),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.key_outlined,
                            color: AppTheme.brandPrimary),
                        title: const Text('تغيير كلمة المرور',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: const Text('تتطلب كلمة المرور الحالية',
                            style: TextStyle(fontSize: 11)),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: _changePassword,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.event_outlined,
                            color: AppTheme.brandPrimary),
                        title: const Text('تاريخ الانضمام',
                            style: TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(_joinDate(me.createdAt),
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),
                Card(
                  margin: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.lock_outline, color: AppTheme.brandPrimary),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'هوية التشفير مرتبطة بهذا الجهاز — لا يمكن نسخها '
                            'أو نقلها، وهذه هي ضمانة خصوصيتك.',
                            style: TextStyle(height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: Container(
                  color: Colors.black26,
                  child: const IgnorePointer(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _joinDate(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '—';
    return '${d.year}/${d.month}/${d.day}';
  }

  Widget _sectionLabel(String t) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 6, 8),
        child: Text(
          t,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppTheme.brandSecondary,
          ),
        ),
      );
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.brandPrimary),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_left),
      ),
    );
  }
}

/// v0.1.2 — the mockup's stats strip, fed with real data:
/// المحادثات (local chats) / المحفوظة (server starred) / أيام معنا.
class _NexStatsCard extends StatelessWidget {
  final int chats;
  final Future<int> starredFuture;
  final int days;
  const _NexStatsCard({
    required this.chats,
    required this.starredFuture,
    required this.days,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: AppTheme.card(context, radius: 20),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        textDirection: TextDirection.rtl,
        children: [
          _cell(context, '$chats', 'المحادثات'),
          _divider(isDark),
          FutureBuilder<int>(
            future: starredFuture,
            initialData: 0,
            builder: (_, snap) =>
                _cell(context, '${snap.data ?? 0}', 'المحفوظة'),
          ),
          _divider(isDark),
          _cell(context, '$days', 'يوم معنا'),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, String value, String label) {
    return Expanded(
      child: Column(
        children: [
          ShaderMask(
            shaderCallback: (r) =>
                AppTheme.accentGradient.createShader(r),
            blendMode: BlendMode.srcIn,
            child: Text(value,
                style: const TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 2),
          Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(fontSize: 11)),
        ],
      ),
    );
  }

  Widget _divider(bool isDark) => Container(
        width: 1,
        height: 30,
        color: isDark
            ? AppTheme.darkBorder.withValues(alpha: 0.6)
            : const Color(0xFFECE6FA),
      );
}

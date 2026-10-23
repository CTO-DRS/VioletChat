import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/app_config.dart';
import '../../data/models/models.dart';
import '../../features/admin/admin_panel_screen.dart';
import '../../routing/app_router.dart';
import '../../services/device_security_service.dart';
import '../../services/update_service.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../state/settings_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';
import '../../widgets/upgrade_dialog.dart';
import '../../widgets/verified_badge.dart';

/// الإعدادات: الملف الشخصي، المظهر، الإشعارات، الخصوصية، الأمان،
/// الأجهزة، البيانات، والحساب.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _exporting = false;

  /// v0.1.9 — حالة الفحص اليدوي للتحديث.
  bool _checkingUpdate = false;

  /// v0.1.0: null until the (cached) availability check resolves —
  /// the app-lock switch stays disabled/“غير متوفر” meanwhile.
  bool? _biometricsAvailable;

  @override
  void initState() {
    super.initState();
    DeviceSecurityService.biometricsAvailable().then((ok) {
      if (mounted) setState(() => _biometricsAvailable = ok);
    });
  }

  AppServices get _services => context.read<AppServices>();

  static String _graceLabel(int secs) {
    switch (secs) {
      case 60:
        return 'القفل بعد دقيقة من الخروج من التطبيق';
      case 300:
        return 'القفل بعد 5 دقائق من الخروج من التطبيق';
      default:
        return 'فوري — القفل عند كل خروج من التطبيق';
    }
  }

  Future<void> _pickLockGrace(UserSettings settings) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (dlgCtx) => SimpleDialog(
        title: const Text('جدول القفل'),
        // v0.1.0: RadioListTile's groupValue/onChanged are deprecated in
        // Flutter 3.35 — RadioGroup ancestor replaces them.
        children: [
          RadioGroup<int>(
            groupValue: settings.appLockGraceSecs,
            onChanged: (x) => Navigator.pop(dlgCtx, x),
            child: Column(
              children: [
                for (final v in const [0, 60, 300])
                  RadioListTile<int>(
                    value: v,
                    title: Text(_graceLabel(v)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await context
        .read<SettingsController>()
        .update(_copy(settings, lockGrace: picked));
    setState(() {});
  }

  UserSettings _copy(
    UserSettings s, {
    bool? darkMode,
    String? themeMode,
    bool? preview,
    bool? sound,
    bool? vibration,
    bool? receipts,
    bool? presence,
    bool? appLock,
    bool? blockShots,
    int? lockGrace,
    int? chatFont,
  }) =>
      UserSettings(
        darkMode: darkMode ?? s.darkMode,
        themeMode: themeMode ?? s.themeMode,
        notificationPreview: preview ?? s.notificationPreview,
        notificationSound: sound ?? s.notificationSound,
        notificationVibration: vibration ?? s.notificationVibration,
        readReceipts: receipts ?? s.readReceipts,
        showPresence: presence ?? s.showPresence,
        appLock: appLock ?? s.appLock,
        blockScreenshots: blockShots ?? s.blockScreenshots,
        appLockGraceSecs: lockGrace ?? s.appLockGraceSecs,
        chatFontSize: chatFont ?? s.chatFontSize,
      );

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  // ===================================================================
  // v0.1.9 — فحص التحديث اليدوي (بلاطلة الإصدار أسفل الإعدادات)
  // ===================================================================
  Future<void> _checkForUpdates() async {
    setState(() => _checkingUpdate = true);
    final info = await UpdateService.checkLatest();
    if (!mounted) return;
    setState(() => _checkingUpdate = false);
    if (info == null) {
      _snack('تعذر التحقق — تحقق من الاتصال وأعد المحاولة');
      return;
    }
    if (!info.isUpgradeAvailable) {
      _snack('أنت على أحدث إصدار (${info.latestVersion})');
      return;
    }
    if (!mounted) return;
    showUpgradeDialog(context, info);
  }

  // ===================================================================
  // Profile edit — v0.1.0 moved to the full ProfileScreen (avatar,
  // username, email, password). The old inline dialog is gone; the
  // header below now navigates to AppRoutes.profile.
  // ===================================================================

  // ===================================================================
  // Blocked list
  // ===================================================================
  Future<void> _blockedDialog() async {
    List<Profile> blocked = [];
    bool loading = true;
    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setDlgState) {
          Future<void> reload() async {
            try {
              final list = await _services.profiles.listBlocked();
              setDlgState(() {
                blocked = list;
                loading = false;
              });
            } catch (_) {
              setDlgState(() => loading = false);
            }
          }

          if (loading) {
            reload();
          }
          return AlertDialog(
            title: const Text('قائمة المحجوبين'),
            content: SizedBox(
              width: 320,
              height: 300,
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : blocked.isEmpty
                      ? const Center(
                          child: Text('لا يوجد مستخدمون محجوبون',
                              textAlign: TextAlign.center),
                        )
                      : ListView.builder(
                          itemCount: blocked.length,
                          itemBuilder: (ctx, i) {
                            final p = blocked[i];
                            return ListTile(
                              dense: true,
                              leading: AvatarWidget(profile: p, radius: 16),
                              title: Text(p.title,
                                  style: const TextStyle(fontSize: 14)),
                              subtitle: Text('@${p.username}',
                                  style: const TextStyle(fontSize: 11)),
                              trailing: TextButton(
                                onPressed: () async {
                                  try {
                                    await _services.profiles.unblock(p.id);
                                    await reload();
                                    _snack('تم إلغاء حجب ${p.title}');
                                  } catch (_) {
                                    _snack('تعذر إلغاء الحجب');
                                  }
                                },
                                child: const Text('إلغاء الحجب'),
                              ),
                            );
                          },
                        ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dlgCtx),
                child: const Text('إغلاق'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===================================================================
  // Devices
  // ===================================================================
  Future<void> _devicesDialog() async {
    List<Device> devices = [];
    bool loading = true;
    final currentDeviceId = _services.identity.deviceId;
    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setDlgState) {
          if (loading) {
            _services.profiles.listDevices().then((list) {
              setDlgState(() {
                devices = list;
                loading = false;
              });
            }).catchError((_) {
              setDlgState(() => loading = false);
            });
          }
          return AlertDialog(
            title: const Text('الأجهزة المتصلة'),
            content: SizedBox(
              width: 340,
              height: 320,
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : devices.isEmpty
                      ? const Center(
                          child: Text('تعذر تحميل الأجهزة',
                              textAlign: TextAlign.center))
                      : Column(
                          children: [
                            Expanded(
                              child: ListView.builder(
                                itemCount: devices.length,
                                itemBuilder: (ctx, i) {
                                  final d = devices[i];
                                  final isCurrent =
                                      d.deviceId == currentDeviceId;
                                  return ListTile(
                                    dense: true,
                                    leading: Icon(
                                      isCurrent
                                          ? Icons.phone_android
                                          : Icons.devices_other,
                                      color: isCurrent
                                          ? AppTheme.successColor
                                          : AppTheme.brandSecondary,
                                    ),
                                    title: Text(
                                      d.deviceName.isEmpty
                                          ? 'جهاز'
                                          : d.deviceName,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                    subtitle: Text(
                                      isCurrent
                                          ? 'هذا الجهاز — ${d.platform}'
                                          : '${d.platform} — آخر ظهور: ${_shortDate(d.lastActiveAt ?? d.createdAt)}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                    trailing: isCurrent
                                        ? Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: AppTheme.successColor
                                                  .withValues(alpha: 0.18),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: const Text('نشط',
                                                style: TextStyle(
                                                    fontSize: 10,
                                                    color:
                                                        AppTheme.successColor)),
                                          )
                                        : null,
                                  );
                                },
                              ),
                            ),
                            const SizedBox(height: 8),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppTheme.errorColor,
                                side: const BorderSide(
                                    color: AppTheme.errorColor),
                              ),
                              onPressed: devices.length <= 1
                                  ? null
                                  : () async {
                                      final ok = await _confirmBool(
                                        'خروج من بقية الأجهزة',
                                        'سيتم تسجيل الخروج من كل الأجهزة '
                                            'الأخرى وإبطال جلساتها. ستحتاج '
                                            'لتسجيل الدخول من جديد عليها.',
                                        'خروج',
                                      );
                                      if (!ok) return;
                                      try {
                                        await _services.profiles
                                            .signOutOtherSessions();
                                        if (dlgCtx.mounted) {
                                          Navigator.pop(dlgCtx);
                                        }
                                        _snack(
                                            'تم تسجيل الخروج من بقية الأجهزة');
                                      } catch (_) {
                                        _snack('تعذر تنفيذ العملية');
                                      }
                                    },
                              icon: const Icon(Icons.phonelink_erase, size: 18),
                              label: const Text('خروج من بقية الأجهزة'),
                            ),
                          ],
                        ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dlgCtx),
                child: const Text('إغلاق'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ===================================================================
  // Export my data
  // ===================================================================
  Future<void> _exportData() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final me = await _services.profiles.getMyProfile();
      final chats = await _services.cache.chats();
      final messages = await _services.cache.search('');
      final data = {
        'app': AppConfig.appName,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'profile': {
          'username': me.username,
          'display_name': me.displayName,
          'bio': me.bio,
          'created_at': me.createdAt,
        },
        'chats': [
          for (final c in chats)
            {
              'id': c.id,
              'type': c.type,
              'title': c.title,
              'last_message_at': c.lastMessageAt,
            },
        ],
        'messages': [
          for (final m in messages)
            {
              'chat_id': m.chatId,
              'kind': m.kind,
              if (m.text != null) 'text': m.text,
              'created_at': m.createdAt,
            },
        ],
      };
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/drs_nexora_export_${DateTime.now().millisecondsSinceEpoch}.json');
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data),
          flush: true);
      await Share.shareXFiles([XFile(file.path)],
          subject: 'نسخة من بياناتي في ${AppConfig.appName}');
    } catch (_) {
      _snack('تعذر تصدير البيانات');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ===================================================================
  // Account
  // ===================================================================
  Future<void> _signOut() async {
    final ok = await _confirmBool(
      'تسجيل الخروج',
      'سيتم مسح مفاتيح الجلسة والرسائل المخزنة محلياً على هذا الجهاز. '
          'عند تسجيل الدخول من جديد ستُستعاد الرسائل من التشفير.',
      'خروج',
    );
    if (!ok) return;
    if (!mounted) return;
    try {
      await context.read<AuthController>().signOut();
    } catch (_) {
      _snack('تعذر تسجيل الخروج — أعد المحاولة');
    }
  }

  Future<void> _deleteAccount() async {
    final first = await _confirmBool(
      'حذف الحساب نهائياً',
      'سيتم حذف حسابك وملفك الشخصي وجميع محادثاتك نهائياً. هذا الإجراء '
          'لا يمكن التراجع عنه.',
      'متابعة',
    );
    if (!first) return;
    final second = await _confirmBool(
      'تأكيد أخير',
      'هل أنت متأكد تماماً من حذف الحساب نهائياً؟ لا يوجد استرجاع بعد الآن.',
      'حذف نهائياً',
    );
    if (!second) return;
    try {
      await _services.profiles.deleteMyAccount();
      if (!mounted) return;
      await context.read<AuthController>().signOut();
    } catch (_) {
      _snack('تعذر حذف الحساب — أعد المحاولة');
    }
  }

  Future<bool> _confirmBool(String title, String body, String action) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: Text(title),
        content: Text(body, textAlign: TextAlign.right),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
              minimumSize: const Size(110, 44),
            ),
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return res == true;
  }

  static String _shortDate(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '—';
    return '${d.day}/${d.month}/${d.year}';
  }

  // ===================================================================
  // Build
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsController>().settings;
    final me = context.watch<AuthController>().me;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('الإعدادات'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            _profileHeader(me),
            // v0.1.1: platform admin panel — visible to admins only.
            if (me?.isPlatformAdmin ?? false) ...[
              const SizedBox(height: 10),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.admin_panel_settings_rounded,
                      color: Color(0xFF38BDF8)),
                  title: const Text('لوحة الإدارة',
                      style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: const Text('المستخدمون، الحظر، التوثيق، الأدوار'),
                  trailing: const Icon(Icons.arrow_back_ios_new, size: 15),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AdminPanelScreen())),
                ),
              ),
            ],
            _sectionTitle('المظهر'),
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.brightness_6,
                            color: AppTheme.brandSecondary, size: 22),
                        SizedBox(width: 12),
                        Text('نمط الواجهة'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // v0.1.0: three-way theme — replaces the binary
                    // night switch (the old dark_mode flag stays as
                    // the server-side fallback for older clients).
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                            value: 'dark',
                            label: Text('داكن'),
                            icon: Icon(Icons.dark_mode, size: 17)),
                        ButtonSegment(
                            value: 'light',
                            label: Text('فاتح'),
                            icon: Icon(Icons.light_mode, size: 17)),
                        ButtonSegment(
                            value: 'system',
                            label: Text('النظام'),
                            icon: Icon(Icons.phone_android, size: 17)),
                      ],
                      selected: {settings.resolvedThemeMode},
                      showSelectedIcon: false,
                      onSelectionChanged: (sel) => context
                          .read<SettingsController>()
                          .update(_copy(settings, themeMode: sel.first)),
                    ),
                    const SizedBox(height: 16),
                    // v0.1.9 — حجم خط المحادثة: يُطبّق فوراً على نص
                    // الرسائل (نص + وسائط) في كل المحادثات.
                    Row(
                      children: [
                        const Icon(Icons.format_size,
                            color: AppTheme.brandSecondary, size: 22),
                        const SizedBox(width: 12),
                        const Text('حجم خط المحادثة'),
                        const Spacer(),
                        Text('${settings.chatFontSize}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppTheme.brandSecondary)),
                      ],
                    ),
                    Slider(
                      value: settings.chatFontSize.toDouble(),
                      min: UserSettings.minChatFontSize.toDouble(),
                      max: UserSettings.maxChatFontSize.toDouble(),
                      divisions: UserSettings.maxChatFontSize -
                          UserSettings.minChatFontSize,
                      label: '${settings.chatFontSize}',
                      onChanged: (v) => context
                          .read<SettingsController>()
                          .update(_copy(settings,
                              chatFont: v.round())),
                    ),
                    // معاينة حية بنفس حجم التطبيق الفعلي
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        'مرحباً! هذه معاينة لحجم رسائلك المشفرة 🔐',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontSize:
                                settings.chatFontSize.toDouble(),
                            height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _sectionTitle('الإشعارات'),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.visibility,
                        color: AppTheme.brandSecondary),
                    title: const Text('معاينة الرسالة'),
                    subtitle: const Text('إظهار نص الرسالة في التنبيه',
                        style: TextStyle(fontSize: 11)),
                    value: settings.notificationPreview,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, preview: v)),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_active,
                        color: AppTheme.brandSecondary),
                    title: const Text('صوت التنبيه'),
                    value: settings.notificationSound,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, sound: v)),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.vibration,
                        color: AppTheme.brandSecondary),
                    title: const Text('الاهتزاز'),
                    value: settings.notificationVibration,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, vibration: v)),
                  ),
                ],
              ),
            ),
            _sectionTitle('الخصوصية'),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading:
                        const Icon(Icons.block, color: AppTheme.brandSecondary),
                    title: const Text('قائمة المحجوبين'),
                    onTap: _blockedDialog,
                    trailing: const Icon(Icons.chevron_left, size: 20),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.done_all,
                        color: AppTheme.brandSecondary),
                    title: const Text('إيصالات القراءة'),
                    subtitle: const Text('إعلام الطرف الآخر عندما تقرأ رسائله',
                        style: TextStyle(fontSize: 11)),
                    value: settings.readReceipts,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, receipts: v)),
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.visibility,
                        color: AppTheme.brandSecondary),
                    title: const Text('إظهار حالة الاتصال'),
                    subtitle: const Text(
                        'إظهار "متصل الآن" للمستخدمين الذين تتشارك معهم محادثة',
                        style: TextStyle(fontSize: 11)),
                    value: settings.showPresence,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, presence: v)),
                  ),
                  const Divider(height: 1),
                  // v0.1.0 device privacy — opt-in, local, fail-safe.
                  SwitchListTile(
                    secondary: const Icon(Icons.fingerprint_rounded,
                        color: AppTheme.brandSecondary),
                    title: const Text('قفل التطبيق بالبصمة'),
                    subtitle: Text(
                      _biometricsAvailable == true
                          ? 'طلب البصمة/الوجه عند كل فتح للتطبيق أو عودته من الخلفية'
                          : 'غير متوفر — لا توجد بصمة/وجه مسجلة على هذا الجهاز',
                      style: const TextStyle(fontSize: 11),
                    ),
                    value: settings.appLock && _biometricsAvailable == true,
                    onChanged: _biometricsAvailable == true
                        ? (v) => context
                            .read<SettingsController>()
                            .update(_copy(settings, appLock: v))
                        : null,
                  ),
                  // v0.1.0: grace window before the lock re-engages
                  // after backgrounding (cold starts always lock).
                  if (settings.appLock && _biometricsAvailable == true) ...[
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.timer_outlined,
                          color: AppTheme.brandSecondary),
                      title: const Text('جدول القفل'),
                      subtitle: Text(
                        _graceLabel(settings.appLockGraceSecs),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: const Icon(Icons.chevron_left, size: 20),
                      onTap: () => _pickLockGrace(settings),
                    ),
                  ],
                  const Divider(height: 1),
                  SwitchListTile(
                    secondary: const Icon(Icons.no_photography_rounded,
                        color: AppTheme.brandSecondary),
                    title: const Text('منع لقطات الشاشة'),
                    subtitle: const Text(
                        'حجب محتوى التطبيق من لقطات الشاشة والتسجيل وشاشة التطبيقات الأخيرة',
                        style: TextStyle(fontSize: 11)),
                    value: settings.blockScreenshots,
                    onChanged: (v) => context
                        .read<SettingsController>()
                        .update(_copy(settings, blockShots: v)),
                  ),
                ],
              ),
            ),
            _sectionTitle('الأمان'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading:
                    const Icon(Icons.security, color: AppTheme.brandSecondary),
                title: const Text('الأمان والتشفير'),
                subtitle: const Text('التحقق من الهوية ورقم الأمان',
                    style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_left, size: 20),
                onTap: () => Navigator.pushNamed(context, AppRoutes.security),
              ),
            ),
            _sectionTitle('الأجهزة'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading:
                    const Icon(Icons.devices, color: AppTheme.brandSecondary),
                title: const Text('الأجهزة المتصلة'),
                subtitle: const Text('إدارة الجلسات النشطة لحسابك',
                    style: TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.chevron_left, size: 20),
                onTap: _devicesDialog,
              ),
            ),
            _sectionTitle('البيانات'),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: _exporting
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.file_download,
                        color: AppTheme.brandSecondary),
                title: const Text('تصدير بياناتي'),
                subtitle: const Text(
                    'ملف JSON يشمل ملفك الشخصي ومحادثاتك ورسائلك',
                    style: TextStyle(fontSize: 11)),
                onTap: _exporting ? null : _exportData,
              ),
            ),
            _sectionTitle('الحساب'),
            Card(
              margin: EdgeInsets.zero,
              child: Column(
                children: [
                  ListTile(
                    leading:
                        const Icon(Icons.logout, color: AppTheme.errorColor),
                    title: const Text('تسجيل الخروج',
                        style: TextStyle(color: AppTheme.errorColor)),
                    onTap: _signOut,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.delete_forever,
                        color: AppTheme.errorColor),
                    title: const Text('حذف الحساب نهائياً',
                        style: TextStyle(color: AppTheme.errorColor)),
                    subtitle: const Text('إجراء لا يمكن التراجع عنه',
                        style: TextStyle(fontSize: 11)),
                    onTap: _deleteAccount,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: _checkingUpdate
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.system_update_alt_rounded,
                        color: AppTheme.brandSecondary),
                title: const Text(AppConfig.appName,
                    style: TextStyle(fontWeight: FontWeight.w800)),
                subtitle: const Text(
                  'الإصدار ${AppConfig.appVersion} — مبني بتقنية تشفير '
                  'X3DH + Double Ratchet',
                  style: TextStyle(fontSize: 11),
                ),
                trailing: const Icon(Icons.chevron_left),
                onTap: _checkingUpdate ? null : _checkForUpdates,
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _profileHeader(Profile? me) {
    if (me == null) {
      return const Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              AvatarWidget(profile: me, radius: 27),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // v0.1.1: verification badge + admin chip in header
                    Row(
                      children: [
                        Flexible(
                          child: Text(me.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800)),
                        ),
                        if (me.isVerified) ...[
                          const SizedBox(width: 3),
                          const VerifiedBadge(size: 15),
                        ],
                        if (me.isPlatformAdmin) ...[
                          const SizedBox(width: 5),
                          const AdminChip(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('@${me.username}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.brandSecondary)),
                    if ((me.bio ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(me.bio!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                    ],
                  ],
                ),
              ),
              // v0.1.0: was AppTheme.darkTextDim — a dark-mode color,
              // nearly invisible on the light profile card.
              Icon(Icons.edit,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 18, 6, 8),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: AppTheme.brandSecondary,
        ),
      ),
    );
  }
}

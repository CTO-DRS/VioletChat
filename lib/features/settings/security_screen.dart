import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../crypto/primitives.dart';
import '../../crypto/safety_number.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_theme.dart';

/// الأمان والتشفير: حالة هوية الجهاز، رقم الأمان، وشرح مبسّط
/// لبروتوكول التشفير (X3DH + Double Ratchet + تدوير مفتاح المجموعة).
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  late Future<SecurityStatus> _statusFuture;
  late Future<String> _safetyFuture;

  @override
  void initState() {
    super.initState();
    _refreshFutures();
  }

  void _refreshFutures() {
    _statusFuture = context.read<AuthController>().securityStatus();
    _safetyFuture = _computeSafetyNumber();
  }

  Future<String> _computeSafetyNumber() async {
    final identityPubB64 =
        await Primitives.x25519Pub(context.read<AppServices>().identity.ik);
    return SafetyNumber.forKey(identityPubB64);
  }

  Future<void> _reRegisterDevice() async {
    final auth = context.read<AuthController>();
    await auth.bootstrap();
    if (!mounted) return;
    setState(_refreshFutures);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
          content:
              Text('تمت إعادة تسجيل هوية الجهاز — أعد التحقق من رقم الأمان مع '
                  'محادثاتك')));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_forward),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: const Text('الأمان والتشفير'),
        ),
        body: FutureBuilder<SecurityStatus>(
          future: _statusFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (var i = 0; i < 4; i++)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      height: 90,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                ],
              );
            }
            if (snap.hasError || snap.data == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off,
                        color: AppTheme.brandSecondary, size: 42),
                    const SizedBox(height: 12),
                    const Text('تعذر تحميل حالة الأمان'),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () => setState(_refreshFutures),
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              );
            }
            final status = snap.data!;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _statusCard(status),
                const SizedBox(height: 14),
                _safetyNumberCard(),
                const SizedBox(height: 14),
                _educationCard(),
                const SizedBox(height: 20),
              ],
            );
          },
        ),
      ),
    );
  }

  // ===================================================================
  // Cards
  // ===================================================================
  Widget _statusCard(SecurityStatus status) {
    final ok = status.identityMatch;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.verified_user : Icons.warning_amber,
                  color: ok ? AppTheme.successColor : AppTheme.errorColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    ok ? 'هوية هذا الجهاز مطابقة' : 'تحذير: هوية غير مطابقة',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                      color: ok ? AppTheme.successColor : AppTheme.errorColor,
                    ),
                  ),
                ),
              ],
            ),
            if (!ok) ...[
              const SizedBox(height: 8),
              const Text(
                'هوية التشفير المحفوظة على هذا الجهاز لا تطابق سجل الخادم '
                '(يحدث عادةً بعد إعادة تثبيت التطبيق). الرسائل القديمة '
                'الموجهة للهوية السابقة لن تُفك هنا.',
                style: TextStyle(fontSize: 12, height: 1.6),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 10),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.errorColor,
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: _reRegisterDevice,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('إعادة تسجيل الجهاز'),
              ),
            ],
            const Divider(height: 24),
            _kvRow('البروتوكول', status.protocol),
            _kvRow('معرّف الجهاز', _shorten(status.deviceId)),
            _kvRow('عدد الأجهزة المسجلة', '${status.deviceCount}'),
          ],
        ),
      ),
    );
  }

  Widget _safetyNumberCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.fingerprint, color: AppTheme.brandSecondary),
                SizedBox(width: 10),
                Text('رقم الأمان',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'قارن هذا الرقم وجهاً لوجه مع الطرف الآخر للتأكد من عدم وجود '
              'أي اعتراض على الاتصال. تطابق الرقمين = لا أحد يستمع.',
              style: TextStyle(fontSize: 12, height: 1.6),
              textAlign: TextAlign.right,
            ),
            const SizedBox(height: 12),
            FutureBuilder<String>(
              future: _safetyFuture,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Container(
                    height: 120,
                    alignment: Alignment.center,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  );
                }
                if (snap.hasError || snap.data == null) {
                  return const Text('تعذر حساب رقم الأمان',
                      style: TextStyle(color: AppTheme.errorColor));
                }
                final groups = snap.data!.split(' ');
                return Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    childAspectRatio: 2.4,
                    padding: EdgeInsets.zero,
                    mainAxisSpacing: 4,
                    children: [
                      for (final g in groups)
                        Center(
                          child: Text(
                            g,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _educationCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 14),
          leading: const Icon(Icons.school, color: AppTheme.brandSecondary),
          title: const Text('كيف يعمل التشفير؟',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          children: [
            _eduItem(
              Icons.key,
              'الاتفاق على السر (X3DH)',
              'عند بدء محادثة جديدة يتبادل الجهازان مفاتيح عمومية (هوية + '
                  'مفاتيح مؤقتة لمرة واحدة) ويشتق كل منهما سراً مشتركاً '
                  'بمعادلة X25519. السر نفسه لا يمر عبر الشبكة أبداً.',
            ),
            _eduItem(
              Icons.radar,
              'قفل متقدم لكل رسالة (Double Ratchet)',
              'كل رسالة تُشفَّر بمفتاح جديد مشتق من السابقة (سلسلة إرسال '
                  'وسلسلة استقبال). حتى لو تسرّب مفتاح لاحق فلن يفكّ '
                  'الرسائل الأقدم — تقدم أمامي للسرية.',
            ),
            _eduItem(
              Icons.group_work,
              'مجموعات وتدوير المفتاح',
              'في المجموعات يُغلَّف مفتاح المجموعة لكل جهاز عضو على حدة، '
                  'وعند أي إضافة أو إزالة يُنشأ إصدار جديد من المفتاح '
                  'لا يستطيع العضو المنزوع فكّ الرسائل بعده.',
            ),
            _eduItem(
              Icons.phone_android,
              'مفاتيحك لا تغادر جهازك',
              'المفاتيح الخاصة مخزّنة في ذاكرة مشفرة عتادياً (Keystore) '
                  'على هذا الجهاز فقط، والخادم يرى نصوصاً مشفرة لا يملك '
                  'مفتاح فكّها.',
            ),
          ],
        ),
      ),
    );
  }

  // ===================================================================
  // Helpers
  // ===================================================================
  Widget _eduItem(IconData icon, String title, String body) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppTheme.brandSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 3),
                Text(
                  body,
                  style: const TextStyle(fontSize: 12, height: 1.7),
                  textAlign: TextAlign.right,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.left,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: AppTheme.brandSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _shorten(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 8)}…${id.substring(id.length - 4)}';
  }
}

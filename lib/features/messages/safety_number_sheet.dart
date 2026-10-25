import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../crypto/primitives.dart';
import '../../crypto/safety_number.dart';
import '../../data/models/models.dart';
import '../../state/app_services.dart';
import '../../theme/app_theme.dart';

/// رقم الأمان للمحادثة (audit 2026-10-25).
///
/// THE REAL PATH: the number is computed from the pair
/// (my device identity key, peer device identity key) — exactly the
/// keys the X3DH handshake actually used, read from the `devices`
/// table the same way bundles are. This is what makes out-of-band
/// verification meaningful: both sides of THIS conversation see the
/// same digits when no man-in-the-middle holds substitute identities.
///
/// قبل هذا الإصلاح كانت شاشة الإعدادات تعرض بصمة هوية الجهاز المحلي
/// وحده (forKey(myIK)) — رقماً لا يمكن مقارنته مع الطرف الآخر أصلاً.
/// التحقق الحقيقي يصبح متاحاً الآن من قائمة كل محادثة ثنائية.
Future<void> showSafetyNumberSheet(BuildContext context, Chat chat) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: _SafetySheet(chat: chat),
    ),
  );
}

class _SafetySheet extends StatefulWidget {
  final Chat chat;
  const _SafetySheet({required this.chat});

  @override
  State<_SafetySheet> createState() => _SafetySheetState();
}

class _SafetySheetState extends State<_SafetySheet> {
  late Future<List<(String, String)>> _future;

  @override
  void initState() {
    super.initState();
    _future = _compute();
  }

  /// (peerDeviceId, safetyNumber) لكل جهاز غير مسحوب للطرف الآخر.
  Future<List<(String, String)>> _compute() async {
    final services = context.read<AppServices>();
    final peerId = widget.chat.peer?.id;
    if (peerId == null || peerId.isEmpty) {
      throw StateError('no peer');
    }
    final myIkB64 = await Primitives.x25519Pub(services.identity.ik);
    final devices = await services.chats.peerIdentityKeys(peerId);
    if (devices.isEmpty) {
      throw StateError('peer has no active devices');
    }
    final out = <(String, String)>[];
    for (final (deviceId, peerIk) in devices) {
      out.add((deviceId, await SafetyNumber.forPair(myIkB64, peerIk)));
    }
    return out;
  }

  static String _short(String id) => id.length <= 10
      ? id
      : '${id.substring(0, 6)}…${id.substring(id.length - 3)}';

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.fingerprint, color: AppTheme.brandSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'رقم الأمان — ${widget.chat.title}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'هذا الرقم مشتق من هوية هذا الجهاز وهوية أجهزة الطرف الآخر — '
              'المفاتيح نفسها التي بُنيت عليها جلسة التشفير فعلياً. قارنه '
              'وجهاً لوجه (أو عبر قناة أخرى موثوقة) مع ما يظهر لدى الطرف '
              'الآخر: تطابق الرقمين يعني عدم وجود وسيط يتنصت أو يستبدل '
              'الهويات.',
              style: TextStyle(fontSize: 12.5, height: 1.7),
              textAlign: TextAlign.right,
            ),
            const SizedBox(height: 14),
            Flexible(
              child: FutureBuilder<List<(String, String)>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return Container(
                      height: 120,
                      alignment: Alignment.center,
                      child: const CircularProgressIndicator(strokeWidth: 2),
                    );
                  }
                  if (snap.hasError || snap.data == null || snap.data!.isEmpty) {
                    return const Text(
                      'تعذر حساب رقم الأمان — تأكد من اتصالك ثم أعد المحاولة',
                      style:
                          TextStyle(color: AppTheme.errorColor, height: 1.5),
                      textAlign: TextAlign.right,
                    );
                  }
                  final devices = snap.data!;
                  return ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final (deviceId, number) in devices)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _NumberCard(
                              deviceLabel: _short(deviceId), number: number),
                        ),
                      if (devices.length > 1)
                        const Padding(
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            'الطرف الآخر مسجل من أكثر من جهاز — كل جهاز له '
                            'رقمه الخاص، وأي رقم لا يتطابق يعني هوية '
                            'مستبدلة.',
                            style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.brandSecondary),
                            textAlign: TextAlign.right,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// بطاقة رقم جهاز واحد: 12 مجموعة × 5 أرقام بخط أحادي المسافة.
class _NumberCard extends StatelessWidget {
  final String deviceLabel;
  final String number;
  const _NumberCard({required this.deviceLabel, required this.number});

  @override
  Widget build(BuildContext context) {
    final groups = number.split(' ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'جهاز الطرف الآخر: $deviceLabel',
            style: const TextStyle(
                fontSize: 11, color: AppTheme.brandSecondary),
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: [
              for (final g in groups)
                Text(
                  g,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

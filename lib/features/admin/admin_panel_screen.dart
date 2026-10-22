import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../widgets/brand.dart';
import '../../widgets/verified_badge.dart';

/// v0.1.1 — لوحة الإدارة (platform admin panel).
///
/// يظهر مدخلها في الإعدادات لحملة profiles.role = 'admin' فقط. كل
/// العمليات تمر عبر دوال RPC محمية (is_current_admin) على الخادم:
///   admin_list_users / admin_ban_user / admin_unban_user
///   admin_set_verified / admin_set_role
/// الحظر الحقيقي ينفذه GoTrue (banned_until) فيُمنع المستخدم من أي
/// دخول جديد وتُلغى جلساته القائمة فوراً (حذف refresh tokens).
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _users = const [];
  String _myId = '';

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _myId = _client.auth.currentUser?.id ?? '';
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _client.rpc('admin_list_users');
      setState(() {
        _users = (rows as List)
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _error = 'تعذّر جلب قائمة المستخدمين — تأكد أن حسابك ما زال أدمن.';
        _loading = false;
      });
    }
  }

  // ------------------------------------------------------------------
  // actions
  // ------------------------------------------------------------------
  Future<void> _call(
    String fn,
    Map<String, dynamic> params,
    String successMsg,
  ) async {
    try {
      await _client.rpc(fn, params: params);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(successMsg),
            behavior: SnackBarBehavior.floating),
      );
      await _load();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final msg = _arabicFnError(e);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('فشل تنفيذ الإجراء — أعد المحاولة'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _arabicFnError(PostgrestException e) {
    // client.rpc goes through PostgREST — RAISE EXCEPTION codes surface
    // as PostgrestException(code: SQLSTATE, message: our Arabic key).
    final raw = '${e.code ?? ''} ${e.message} ${e.details ?? ''}';
    if (raw.contains('ADMIN_ONLY')) return 'هذا الإجراء للأدمن فقط';
    if (raw.contains('USER_NOT_FOUND')) return 'المستخدم غير موجود';
    if (raw.contains('BAD_DAYS')) return 'مدة الحظر غير صالحة (1-3650 يوماً)';
    if (raw.contains('BAD_ROLE')) return 'الدور غير صالح';
    if (raw.contains('42501')) return 'صلاحية غير كافية';
    return 'فشل تنفيذ الإجراء';
  }

  Future<void> _actions(Map<String, dynamic> u) async {
    final isSelf = (u['user_id'] as String? ?? '') == _myId;
    final name = (u['username'] ?? '') as String;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('إجراءات: @$name',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            if (isSelf)
              const Padding(
                padding: EdgeInsets.all(10),
                child: Text('هذا حسابك — الحظر وإنزال الدور معطّلان حمايةً',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey)),
              ),
            ListTile(
              leading:
                  const Icon(Icons.block_rounded, color: Colors.redAccent),
              title: const Text('حظر المستخدم'),
              subtitle: const Text('يمنع الدخول فوراً لمدة محددة'),
              onTap: isSelf ? null : () => _pickBanDays(ctx, u),
            ),
            if ((u['banned_until'] as String?) != null)
              ListTile(
                leading: const Icon(Icons.lock_open_rounded,
                    color: Colors.greenAccent),
                title: const Text('رفع الحظر'),
                onTap: () {
                  Navigator.pop(ctx);
                  _call('admin_unban_user', {'p_user': u['user_id']},
                      'رُفع الحظر عن @$name');
                },
              ),
            ListTile(
              leading: Icon(
                (u['is_verified'] as bool? ?? false)
                    ? Icons.verified_outlined
                    : Icons.verified_rounded,
                color: const Color(0xFF38BDF8),
              ),
              title: Text((u['is_verified'] as bool? ?? false)
                  ? 'إزالة علامة التوثيق'
                  : 'منح علامة التوثيق'),
              onTap: () {
                Navigator.pop(ctx);
                final target = !(u['is_verified'] as bool? ?? false);
                _call('admin_set_verified', {
                  'p_user': u['user_id'],
                  'p_verified': target,
                }, target ? 'وُثّق حساب @$name' : 'أُزيل التوثيق عن @$name');
              },
            ),
            ListTile(
              leading: Icon(
                Icons.admin_panel_settings_outlined,
                color: (u['role'] == 'admin')
                    ? Colors.grey
                    : const Color(0xFF7C3AED),
              ),
              title: Text((u['role'] == 'admin')
                  ? 'إزالة صلاحية الأدمن'
                  : 'ترقية إلى أدمن'),
              onTap: (u['role'] == 'admin' && isSelf)
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      final target = (u['role'] == 'admin') ? 'user' : 'admin';
                      _call('admin_set_role', {
                        'p_user': u['user_id'],
                        'p_role': target,
                      },
                          target == 'admin'
                              ? 'أصبح @$name أدمناً'
                              : 'أُزيلت صلاحية الأدمن عن @$name');
                    },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickBanDays(
      BuildContext sheetCtx, Map<String, dynamic> u) async {
    final name = (u['username'] ?? '') as String;
    final choices = <int, String>{
      1: 'يوم واحد',
      7: '7 أيام',
      30: '30 يوماً',
      365: 'سنة كاملة',
    };
    await showModalBottomSheet<void>(
      context: sheetCtx,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Text('مدة الحظر',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            ),
            for (final e in choices.entries)
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text(e.value),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pop(sheetCtx);
                  _call('admin_ban_user', {
                    'p_user': u['user_id'],
                    'p_days': e.key,
                  }, 'حُظر @$name لمدة ${e.value}');
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // helpers
  // ------------------------------------------------------------------
  String _remaining(Object? bannedUntil) {
    final s = bannedUntil as String?;
    if (s == null || s.isEmpty) return '';
    final t = DateTime.tryParse(s);
    if (t == null) return '';
    final d = t.difference(DateTime.now());
    if (d.isNegative) return 'انتهى الحظر فعلياً';
    final days = d.inDays;
    if (days >= 1) return 'محظور — يتبقى $days يوماً';
    return 'محظور — ينتهي خلال ${d.inHours} ساعة';
  }

  String _shortDate(Object? iso) {
    final s = iso as String?;
    if (s == null || s.isEmpty) return '';
    final t = DateTime.tryParse(s)?.toLocal();
    if (t == null) return '';
    return '${t.year}/${t.month}/${t.day}';
  }

  // ------------------------------------------------------------------
  // build
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_forward),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('لوحة الإدارة'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(_error!, textAlign: TextAlign.center),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonal(
                        onPressed: _load,
                        child: const Text('إعادة المحاولة'),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _users.isEmpty
                      ? ListView(children: const [
                          Padding(
                            padding: EdgeInsets.all(40),
                            child: Center(child: Text('لا يوجد مستخدمون بعد')),
                          ),
                        ])
                      : ListView.separated(
                          itemCount: _users.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, indent: 76),
                          itemBuilder: (ctx, i) => _tile(_users[i]),
                        ),
                ),
    );
  }

  Widget _tile(Map<String, dynamic> u) {
    final verified = u['is_verified'] as bool? ?? false;
    final isAdmin = u['role'] == 'admin';
    final isSelf = (u['user_id'] as String? ?? '') == _myId;
    final username = (u['username'] ?? '') as String;
    final display = ((u['display_name'] ?? '') as String).trim();
    final banNote = _remaining(u['banned_until']);

    return ListTile(
      onTap: () => _actions(u),
      leading: AvatarWidget(
        label: display.isNotEmpty ? display : username,
        seedId: u['user_id'] as String? ?? username,
        radius: 22,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              display.isNotEmpty ? display : username,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          if (verified) const VerifiedBadge(size: 15),
          if (isAdmin) ...[
            const SizedBox(width: 5),
            const AdminChip(),
          ],
        ],
      ),
      subtitle: Text(
        '@$username'
        ' • انضم ${_shortDate(u['created_at'])}'
        '${banNote.isEmpty ? '' : ' • $banNote'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          color: banNote.isNotEmpty ? Colors.redAccent : null,
        ),
      ),
      trailing: Icon(
        isSelf ? Icons.person_rounded : Icons.more_vert_rounded,
        size: 18,
      ),
    );
  }
}

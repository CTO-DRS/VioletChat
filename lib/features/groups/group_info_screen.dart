import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/models.dart';
import '../../state/app_services.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// معلومات المجموعة: الأعضاء والأدوار، الدعوات، طلبات الانضمام،
/// إدارة المفتاح (تدوير عند تغيّر الأعضاء)، ومنطقة الخطر.
class GroupInfoScreen extends StatefulWidget {
  final Chat chat;
  const GroupInfoScreen({super.key, required this.chat});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late AppServices _services;

  List<ChatMember> _members = [];
  List<JoinRequest> _requests = [];
  bool _loading = true;
  bool _busy = false;
  int? _keyVersion;
  late String _name;
  late String? _description;

  String? _myId;
  bool get _isOwner => _myRole == AppRoles.owner;
  bool get _isAdmin => _myRole == AppRoles.owner || _myRole == AppRoles.admin;
  String? get _myRole {
    final me = _members.where((m) => m.profile.id == _myId).toList();
    if (me.isNotEmpty) return me.first.role;
    return widget.chat.myRole;
  }

  // True only when loaded members confirm ownership (fallback to the
  // route-provided role while the list is still empty).
  bool get _ownerConfirmed => _isOwner;

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _myId = _services.auth.userId;
    _name = widget.chat.name;
    _description = widget.chat.description;
    _load();
  }

  Future<void> _load() async {
    try {
      final members = await _services.chats.loadMembers(widget.chat.id);
      final requests = widget.chat.myRole == AppRoles.owner
          ? await _services.chats.listJoinRequests(widget.chat.id)
          : <JoinRequest>[];
      int? version;
      try {
        version =
            await _services.sync.crypto.currentGroupVersion(widget.chat.id);
      } catch (_) {
        version = null;
      }
      if (!mounted) return;
      setState(() {
        _members = members;
        _requests = requests;
        _keyVersion = version;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      _err('تعذر تحميل بيانات المجموعة');
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _snack(String msg) => _err(msg);

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('حدث خطأ — أعد المحاولة');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ===================================================================
  // Member actions (owner)
  // ===================================================================
  Future<void> _promoteMember(ChatMember member) async {
    final ok = await _confirm(
      'ترقية إلى مشرف',
      'سيتمكن ${member.profile.title} من إضافة الأعضاء وتعديل معلومات المجموعة.',
      'ترقية',
    );
    if (!ok) return;
    await _runBusy(() async {
      await _services.chats
          .setMemberRole(widget.chat.id, member.profile.id, AppRoles.admin);
      _snack('تمت الترقية إلى مشرف');
      await _load();
    });
  }

  Future<void> _removeMember(ChatMember member) async {
    final ok = await _confirm(
      'إزالة العضو',
      'سيُزال ${member.profile.title} من المجموعة، وسيُدوَّر مفتاح التشفير '
          'لإصدار جديد لا يستطيع فكّه.',
      'إزالة',
      danger: true,
    );
    if (!ok) return;
    await _runBusy(() async {
      await _services.chats
          .removeGroupMember(widget.chat.id, member.profile.id);
      try {
        await _services.sync.crypto.rotateGroupKey(widget.chat.id);
        _snack('تمت الإزالة وتدوير مفتاح المجموعة');
      } catch (_) {
        _snack('تمت الإزالة لكن تعذر تدوير مفتاح المجموعة');
      }
      await _load();
    });
  }

  // ===================================================================
  // Add member
  // ===================================================================
  Future<void> _addMemberSheet() async {
    final searchCtrl = TextEditingController();
    Timer? debounce;
    List<Profile> results = [];
    bool searching = false;
    final existingIds = _members.map((m) => m.profile.id).toSet();

    final picked = await showModalBottomSheet<Profile>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                const Text('إضافة عضو',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: TextField(
                    controller: searchCtrl,
                    autofocus: true,
                    onChanged: (q) {
                      debounce?.cancel();
                      debounce =
                          Timer(const Duration(milliseconds: 400), () async {
                        final query = q.trim();
                        if (query.isEmpty) {
                          setSheetState(() => results = []);
                          return;
                        }
                        setSheetState(() => searching = true);
                        try {
                          final found =
                              await _services.profiles.searchUsers(query);
                          setSheetState(() => results = found
                              .where((p) => !existingIds.contains(p.id))
                              .toList());
                        } catch (_) {
                          setSheetState(() => results = []);
                        } finally {
                          setSheetState(() => searching = false);
                        }
                      });
                    },
                    decoration: const InputDecoration(
                      labelText: 'بحث بالاسم أو المعرّف',
                      prefixIcon: Icon(Icons.person_search),
                    ),
                  ),
                ),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.all(14),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  SizedBox(
                    height: 280,
                    child: results.isEmpty
                        ? Center(
                            // v0.1.0: was Colors.white38 — invisible in light mode.
                            child: Text('ابحث عن مستخدم لإضافته',
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant)))
                        : ListView.builder(
                            itemCount: results.length,
                            itemBuilder: (ctx, i) {
                              final p = results[i];
                              return ListTile(
                                dense: true,
                                title: Text(p.title,
                                    style: const TextStyle(fontSize: 14)),
                                subtitle: Text('@${p.username}',
                                    style: const TextStyle(fontSize: 11)),
                                trailing: const Icon(Icons.person_add_alt,
                                    color: AppTheme.brandSecondary),
                                onTap: () => Navigator.pop(sheetCtx, p),
                              );
                            },
                          ),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      ),
    );
    debounce?.cancel();
    searchCtrl.dispose();
    if (picked == null) return;
    await _runBusy(() async {
      await _services.chats.addGroupMembers(widget.chat.id, [picked.id]);
      try {
        await _services.sync.crypto.rotateGroupKey(widget.chat.id);
        _snack('تمت إضافة ${picked.title} وتدوير مفتاح المجموعة');
      } catch (_) {
        _snack('تمت الإضافة لكن تعذر تدوير مفتاح المجموعة');
      }
      await _load();
    });
  }

  // ===================================================================
  // Invite link
  // ===================================================================
  Future<void> _createInvite() async {
    await _runBusy(() async {
      final code = await _services.chats.createInviteLink(widget.chat.id);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dlgCtx) => AlertDialog(
          title: const Text('رابط الدعوة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('شارك هذا الرابط مع من تثق به فقط:',
                  textAlign: TextAlign.right),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: code));
                Navigator.pop(dlgCtx);
                _snack('تم نسخ رابط الدعوة');
              },
              icon: const Icon(Icons.content_copy, size: 18),
              label: const Text('نسخ'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      );
    });
  }

  // ===================================================================
  // Edit group info (admin)
  // ===================================================================
  Future<void> _editInfo() async {
    final nameCtrl = TextEditingController(text: _name);
    final descCtrl = TextEditingController(text: _description ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('تعديل المجموعة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'اسم المجموعة'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: descCtrl,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'الوصف (اختياري)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final newName = nameCtrl.text.trim();
    if (newName.isEmpty) {
      _err('اسم المجموعة لا يمكن أن يكون فارغاً');
      return;
    }
    final newDesc = descCtrl.text.trim();
    await _runBusy(() async {
      await _services.chats.updateGroupInfo(
        chatId: widget.chat.id,
        name: newName == _name ? null : newName,
        description: newDesc == (_description ?? '') ? null : newDesc,
      );
      if (mounted) {
        setState(() {
          _name = newName;
          _description = newDesc;
        });
      }
      _snack('تم تحديث معلومات المجموعة');
    });
    nameCtrl.dispose();
    descCtrl.dispose();
  }

  // ===================================================================
  // Join requests (owner)
  // ===================================================================
  Future<void> _respond(JoinRequest r, bool accept) async {
    await _runBusy(() async {
      await _services.chats.respondJoinRequest(r.id, accept);
      _snack(accept ? 'تم قبول الطلب' : 'تم رفض الطلب');
      await _load();
    });
  }

  // ===================================================================
  // Leave / delete
  // ===================================================================
  Future<void> _leaveGroup() async {
    final ok = await _confirm(
      'مغادرة المجموعة',
      'لن تستقبل رسائل هذه المجموعة بعد المغادرة. إذا كنت مالكها فسيتم تعيين مشرف بديل تلقائياً على الخادم.',
      'مغادرة',
      danger: true,
    );
    if (!ok) return;
    await _runBusy(() async {
      await _services.chats.leaveGroup(widget.chat.id);
      try {
        await _services.cache.removeChat(widget.chat.id);
      } catch (_) {}
      if (!mounted) return;
      Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  Future<void> _deleteGroup() async {
    final first = await _confirm(
      'حذف المجموعة',
      'سيتم حذف المجموعة نهائياً مع كل رسائلها عند الجميع.',
      'متابعة',
      danger: true,
    );
    if (!first) return;
    final second = await _confirm(
      'تأكيد نهائي',
      'هل أنت متأكد تماماً؟ لا يمكن التراجع عن حذف المجموعة.',
      'حذف نهائياً',
      danger: true,
    );
    if (!second) return;
    await _runBusy(() async {
      await _services.chats.deleteGroup(widget.chat.id);
      try {
        await _services.cache.removeChat(widget.chat.id);
      } catch (_) {}
      if (!mounted) return;
      _snack('تم حذف المجموعة');
      Navigator.of(context).popUntil((r) => r.isFirst);
    });
  }

  Future<bool> _confirm(
    String title,
    String body,
    String action, {
    bool danger = false,
  }) async {
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
              backgroundColor: danger ? AppTheme.errorColor : null,
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

  // ===================================================================
  // Build
  // ===================================================================
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
          title: const Text('معلومات المجموعة'),
        ),
        body: _busy
            ? Stack(
                children: [
                  _body(),
                  Positioned.fill(
                    child: Container(
                      color: Colors.black26,
                      child: const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
                ],
              )
            : _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 6,
        itemBuilder: (ctx, i) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          height: 56,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(),
        const SizedBox(height: 14),
        _securityCard(),
        const SizedBox(height: 14),
        _actionsCard(),
        if (_ownerConfirmed && _requests.isNotEmpty) ...[
          const SizedBox(height: 14),
          _joinRequestsSection(),
        ],
        const SizedBox(height: 14),
        _membersSection(),
        const SizedBox(height: 14),
        _dangerZone(),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _header() {
    final initial = _name.trim().isEmpty ? '؟' : _name.trim().substring(0, 1);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF271B52), Color(0xFF1D1240)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.brandPrimary, Color(0xFF9B4DF0)],
              ),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              initial,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
                if ((_description ?? '').isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    _description!,
                    // v0.1.0: was AppTheme.darkTextDim — invisible on the
                    // light header surface in light mode.
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  '${_members.length} عضو — مجموعة مشفرة',
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.brandSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _securityCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.enhanced_encryption,
              color: AppTheme.brandSecondary, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'تشفير مزدوج: تُشفَّر رسائل المجموعة بمفتاح مجموعة يُغلَّف لكل '
              'جهاز عضو على حدة، ويُدوَّر تلقائياً عند أي تغيّر في '
              'الأعضاء. إصدار المفتاح الحالي: ${_keyVersion == null ? '—' : 'v$_keyVersion'}',
              style: const TextStyle(fontSize: 12, height: 1.6),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionsCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          if (_isAdmin)
            ListTile(
              leading: const Icon(Icons.person_add_alt,
                  color: AppTheme.brandSecondary),
              title: const Text('إضافة عضو'),
              onTap: _addMemberSheet,
            ),
          if (_isAdmin) const Divider(height: 1),
          if (_isAdmin)
            ListTile(
              leading: const Icon(Icons.edit, color: AppTheme.brandSecondary),
              title: const Text('تعديل الاسم والوصف'),
              onTap: _editInfo,
            ),
          if (_isAdmin) const Divider(height: 1),
          if (_isAdmin)
            ListTile(
              leading: const Icon(Icons.link, color: AppTheme.brandSecondary),
              title: const Text('رابط الدعوة'),
              subtitle: const Text('إنشاء رابط انضمام جديد',
                  style: TextStyle(fontSize: 11)),
              onTap: _createInvite,
            ),
        ],
      ),
    );
  }

  Widget _joinRequestsSection() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 4),
            child: Text(
              'طلبات الانضمام (${_requests.length})',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.brandSecondary),
            ),
          ),
          for (final r in _requests)
            ListTile(
              dense: true,
              leading: AvatarWidget(profile: r.profile, radius: 17),
              title:
                  Text(r.profile.title, style: const TextStyle(fontSize: 14)),
              subtitle: Text('@${r.profile.username}',
                  style: const TextStyle(fontSize: 11)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'قبول',
                    icon: const Icon(Icons.check_circle,
                        color: AppTheme.successColor),
                    onPressed: () => _respond(r, true),
                  ),
                  IconButton(
                    tooltip: 'رفض',
                    icon: const Icon(Icons.cancel, color: AppTheme.errorColor),
                    onPressed: () => _respond(r, false),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  Widget _membersSection() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 4),
            child: Text(
              'الأعضاء (${_members.length})',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.brandSecondary),
            ),
          ),
          for (final m in _members) _memberTile(m),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: AppTheme.errorColor),
            title: const Text('مغادرة المجموعة',
                style: TextStyle(color: AppTheme.errorColor)),
            onTap: _leaveGroup,
          ),
        ],
      ),
    );
  }

  Widget _memberTile(ChatMember m) {
    final isMe = m.profile.id == _myId;
    return ListTile(
      dense: true,
      leading: AvatarWidget(profile: m.profile, radius: 17),
      title: Text(
        isMe ? '${m.profile.title} (أنت)' : m.profile.title,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle:
          Text('@${m.profile.username}', style: const TextStyle(fontSize: 11)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _roleBadge(m.role),
          if (_isOwner && !isMe)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (value) {
                if (value == 'promote') _promoteMember(m);
                if (value == 'remove') _removeMember(m);
              },
              itemBuilder: (_) => [
                if (m.role == AppRoles.member)
                  const PopupMenuItem(
                    value: 'promote',
                    child: Text('ترقية إلى مشرف'),
                  ),
                const PopupMenuItem(
                  value: 'remove',
                  child: Text('إزالة العضو',
                      style: TextStyle(color: AppTheme.errorColor)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _roleBadge(String role) {
    final (label, color) = switch (role) {
      AppRoles.owner => ('مالك', AppTheme.brandPrimary),
      AppRoles.admin => ('مشرف', AppTheme.brandAccent),
      _ => ('عضو', Colors.white24),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style:
            TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _dangerZone() {
    if (!_isOwner) return const SizedBox.shrink();
    return Card(
      margin: EdgeInsets.zero,
      color: AppTheme.errorColor.withValues(alpha: 0.07),
      child: ListTile(
        leading: const Icon(Icons.delete_forever, color: AppTheme.errorColor),
        title: const Text('حذف المجموعة نهائياً',
            style: TextStyle(color: AppTheme.errorColor)),
        subtitle: const Text('يُحذف كل شيء عند جميع الأعضاء',
            style: TextStyle(fontSize: 11)),
        onTap: _deleteGroup,
      ),
    );
  }
}

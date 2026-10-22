import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/errors/app_exception.dart';
import '../../data/models/models.dart';
import '../../routing/app_router.dart';
import '../../state/app_services.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// إنشاء مجموعة جديدة: اسم + وصف + اختيار الأعضاء، ثم توليد مفتاح
/// المجموعة وتغليفه لكل جهاز عضو (تشفير مزدوج).
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  Timer? _debounce;
  List<Profile> _results = [];
  final List<Profile> _selected = [];
  bool _searching = false;
  bool _creating = false;

  AppServices get _services => context.read<AppServices>();

  @override
  void dispose() {
    _debounce?.cancel();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ===================================================================
  // Search
  // ===================================================================
  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _doSearch(q));
  }

  Future<void> _doSearch(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _results = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final users = await _services.profiles.searchUsers(query);
      if (!mounted) return;
      setState(() => _results = users);
    } on AppException catch (e) {
      if (!mounted) return;
      _err(e.message);
    } catch (_) {
      if (mounted) _err('تعذر البحث — تحقق من الاتصال');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  bool _isSelected(Profile p) => _selected.any((s) => s.id == p.id);

  void _toggleMember(Profile p) {
    setState(() {
      if (_isSelected(p)) {
        _selected.removeWhere((s) => s.id == p.id);
      } else {
        _selected.add(p);
      }
    });
  }

  // ===================================================================
  // Create flow
  // ===================================================================
  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _err('أدخل اسماً للمجموعة');
      return;
    }
    if (_creating) return;
    setState(() => _creating = true);
    final desc = _descCtrl.text.trim();
    try {
      // 1) إنشاء المجموعة على الخادم.
      final chatId = await _services.chats.createGroup(
        name: name,
        description: desc.isEmpty ? null : desc,
      );
      // 2) إضافة الأعضاء (الخادم ينشئ رسائل النظام تلقائياً).
      if (_selected.isNotEmpty) {
        await _services.chats
            .addGroupMembers(chatId, _selected.map((p) => p.id).toList());
      }
      // 3) توليد مفتاح المجموعة ونشر أغلفته لكل الأجهزة (حتى أجهزتي).
      try {
        await _services.sync.crypto.rotateGroupKey(chatId);
      } catch (_) {
        _err('تم إنشاء المجموعة لكن تعذر توليد مفتاح التشفير');
      }
      // 4) فتح المحادثة مباشرة.
      if (!mounted) return;
      final chat = Chat(
        id: chatId,
        type: 'group',
        name: name,
        description: desc.isEmpty ? null : desc,
        myRole: 'owner',
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      await Navigator.pushReplacementNamed(
        context,
        AppRoutes.chat,
        arguments: chat,
      );
    } on AppException catch (e) {
      _err(e.message);
    } catch (_) {
      _err('تعذر إنشاء المجموعة — أعد المحاولة');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
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
          title: const Text('مجموعة جديدة'),
        ),
        body: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        TextField(
                          controller: _nameCtrl,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'اسم المجموعة',
                            prefixIcon: Icon(Icons.group),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _descCtrl,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'الوصف (اختياري)',
                            prefixIcon: Icon(Icons.notes),
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_selected.isNotEmpty) ...[
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              for (final p in _selected)
                                InputChip(
                                  avatar: _InitialCircle(p.title, p.colorSeed),
                                  label: Text(p.title,
                                      style: const TextStyle(fontSize: 12)),
                                  onDeleted: () => _toggleMember(p),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                        ],
                        TextField(
                          controller: _searchCtrl,
                          onChanged: _onSearchChanged,
                          decoration: const InputDecoration(
                            labelText: 'بحث عن أعضاء بالاسم أو المعرّف',
                            prefixIcon: Icon(Icons.person_search),
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (_searching)
                          const Padding(
                            padding: EdgeInsets.all(18),
                            child: Center(
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          )
                        else if (_results.isEmpty &&
                            _searchCtrl.text.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.all(18),
                            child: Center(
                              child: Text(
                                'لا نتائج مطابقة',
                                // v0.1.0: was Colors.white38 — invisible in light mode.
                                style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant),
                              ),
                            ),
                          )
                        else
                          for (final p in _results)
                            ListTile(
                              dense: true,
                              leading: _InitialCircle(p.title, p.colorSeed),
                              title: Text(p.title,
                                  style: const TextStyle(fontSize: 14)),
                              subtitle: Text('@${p.username}',
                                  style: const TextStyle(fontSize: 11)),
                              trailing: Icon(
                                _isSelected(p)
                                    ? Icons.check_circle
                                    : Icons.add_circle_outline,
                                color: _isSelected(p)
                                    ? AppTheme.successColor
                                    : AppTheme.brandSecondary,
                              ),
                              onTap: () => _toggleMember(p),
                            ),
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.lock,
                                  size: 18, color: AppTheme.brandSecondary),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'مفتاح المجموعة يُغلَّف لكل جهاز عضو على حدة، ولا يمر مكشوفاً عبر الخادم أبداً.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(fontSize: 12),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton.icon(
                      onPressed: _creating ? null : _create,
                      icon: const Icon(Icons.group_add),
                      label: Text(
                        _selected.isEmpty
                            ? 'إنشاء المجموعة'
                            : 'إنشاء المجموعة (${_selected.length} عضو)',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_creating)
              Positioned.fill(
                child: Container(
                  color: Colors.black38,
                  child: const Center(
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(22),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 14),
                            Text('جاري إنشاء المجموعة وتوليد المفتاح...'),
                          ],
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

class _InitialCircle extends StatelessWidget {
  final String name;
  final int seed;
  const _InitialCircle(this.name, this.seed);

  @override
  Widget build(BuildContext context) {
    // v0.1.0: unified AvatarWidget — color math preserved via explicit
    // color so existing identity colors don't shift.
    return AvatarWidget(
      label: name,
      color: AppTheme.avatarPalette[seed % AppTheme.avatarPalette.length],
      radius: 14,
    );
  }
}

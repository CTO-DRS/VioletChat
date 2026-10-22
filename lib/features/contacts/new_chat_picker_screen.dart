import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../routing/app_router.dart';
import '../../state/chats_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';
import '../chats/chat_query.dart';

/// v0.1.7 «إعادة الترتيب الكامل» — شاشة «محادثة جديدة» مستقلة.
///
/// سبب الوجود: زر «محادثة جديدة» في ورقة الإنشاء كان يفتح شاشة البحث
/// الشامل نفسها التي تفتحها أيقونة البحث العلوية — زران يقودان لنفس
/// الشاشة، وهذا ما أصلحه هذه الإصدارة. الآن:
///   • «محادثة جديدة»     → هذه الشاشة (جهات اتصالك المعروفة + تصفية فورية)
///   • أيقونة البحث        → البحث الشامل (مستخدمون جدد ورسائل)
/// مساران مختلفان بوجهتين مختلفتين — لا استنساخ.
class NewChatPickerScreen extends StatefulWidget {
  const NewChatPickerScreen({super.key});

  @override
  State<NewChatPickerScreen> createState() => _NewChatPickerScreenState();
}

class _NewChatPickerScreenState extends State<NewChatPickerScreen> {
  final TextEditingController _field = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  /// جهات الاتصال المعروفة: نظراء المحادثات الفردية مرتبين بأحدث نشاط.
  /// نضيف معها محادثتها الجاهزة إن وُجدت لفتحها فوراً بلمسة واحدة.
  List<({Profile peer, Chat? chat})> _contacts(ChatsController c) {
    final seen = <String>{};
    final out = <({Profile peer, Chat? chat})>[];
    for (final chat in c.chats) {
      final p = chat.peer;
      if (chat.isGroup || p == null) continue;
      if (seen.contains(p.id)) continue;
      seen.add(p.id);
      out.add((peer: p, chat: chat));
    }
    return out;
  }

  /// ISO-8601 نصّياً في النموذج — التحليل هنا مع سقوط آمن.
  DateTime? _parseStamp(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return DateTime.parse(raw).toLocal();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatsController>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final all = _contacts(controller);
    final visible = _query.trim().isEmpty
        ? all
        : all.where((e) => profileMatchesQuery(e.peer, _query)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('محادثة جديدة',
            style: TextStyle(fontWeight: FontWeight.w800)),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: TextField(
              controller: _field,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'صفِّ جهات اتصالك بالاسم أو المعرّف…',
                prefixIcon: const Icon(Icons.search_rounded,
                    color: AppTheme.brandSecondary),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'مسح التصفية',
                        icon: const Icon(Icons.close_rounded, size: 19),
                        onPressed: () {
                          _field.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                fillColor: isDark
                    ? AppTheme.darkSurface.withValues(alpha: 0.9)
                    : Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                      color: isDark
                          ? AppTheme.darkBorder
                          : const Color(0xFFECE6FA)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(
                      color: isDark
                          ? AppTheme.darkBorder
                          : const Color(0xFFECE6FA)),
                ),
              ),
            ),
          ),
          Expanded(
            child: all.isEmpty
                ? _NoContacts(
                    onGlobalSearch: () =>
                        Navigator.pushNamed(context, AppRoutes.search))
                : visible.isEmpty
                    ? _NoLocalMatches(
                        query: _query,
                        onGlobalSearch: () =>
                            Navigator.pushNamed(context, AppRoutes.search))
                    : ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 32, top: 6),
                        itemCount: visible.length,
                        itemBuilder: (ctx, i) {
                          final e = visible[i];
                          final stamp = _parseStamp(
                              e.chat?.lastMessageAt ?? e.chat?.createdAt);
                          return ListTile(
                            leading: AvatarWidget(profile: e.peer, radius: 22),
                            title: Text(e.peer.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              stamp == null
                                  ? '@${e.peer.username}'
                                  : 'آخر نشاط: ${SmartDate.listStamp(stamp)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(
                                Icons.chat_bubble_outline_rounded,
                                size: 19,
                                color: AppTheme.brandSecondary),
                            onTap: () {
                              final chat = e.chat;
                              if (chat != null) {
                                Navigator.pushNamed(context, AppRoutes.chat,
                                    arguments: chat);
                              } else {
                                Navigator.pushNamed(
                                    context, AppRoutes.search);
                              }
                            },
                          );
                        },
                      ),
          ),
          // المدخل الاحتياطي الوحيد للبحث الشامل داخل هذه الشاشة —
          // سياقي وليس زراً مكرراً في الأعلى.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      Navigator.pushNamed(context, AppRoutes.search),
                  icon: const Icon(Icons.travel_explore_rounded, size: 19),
                  label: const Text('لا تجده بين جهات اتصالك؟ ابحث شاملاً'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoContacts extends StatelessWidget {
  final VoidCallback onGlobalSearch;
  const _NoContacts({required this.onGlobalSearch});

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: AppTheme.brandPrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(Icons.contacts_outlined,
                  size: 40, color: AppTheme.brandSecondary),
            ),
            const SizedBox(height: 18),
            Text('لا جهات اتصال بعد',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'جهات اتصالك تظهر هنا بعد أول محادثة. ابحث الآن عن مستخدم بالاسم أو المعرّف لتبدأ أول محادثة مشفرة.',
              textAlign: TextAlign.center,
              style: dim,
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onGlobalSearch,
              icon: const Icon(Icons.person_search_rounded, size: 19),
              label: const Text('بحث شامل عن مستخدم'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoLocalMatches extends StatelessWidget {
  final String query;
  final VoidCallback onGlobalSearch;
  const _NoLocalMatches({required this.query, required this.onGlobalSearch});

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 44, color: AppTheme.brandSecondary),
            const SizedBox(height: 14),
            Text('لا نتائج محلية عن «$query»',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'جهات اتصالك المعروفة فقط تُصفّى هنا — المستخدمون الآخرون عبر البحث الشامل.',
              textAlign: TextAlign.center,
              style: dim,
            ),
          ],
        ),
      ),
    );
  }
}

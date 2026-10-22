import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exception.dart';
import '../../data/models/models.dart';
import '../../routing/app_router.dart';
import '../../state/app_services.dart';
import '../../state/chats_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/brand.dart';

/// Global search — users / local messages / my chats.
class SearchScreen extends StatefulWidget {
  /// v0.1.6: استعلام مبدئي اختياري — يُعبّأ في الحقل ويُشغّل
  /// البحث تلقائياً عند الفتح (مثلاً من ورقة «إضافة صديق»).
  final String? initialQuery;
  const SearchScreen({super.key, this.initialQuery});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final TextEditingController _query;
  late final AppServices _services;
  Timer? _debounce;

  bool _searching = false;
  bool _netError = false;
  String? _openingId;

  List<Profile> _users = [];
  List<Message> _messages = [];
  List<Chat> _myChats = [];
  Map<String, Chat> _chatsById = {};

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _tab = TabController(length: 3, vsync: this);
    // النص يُضبط قبل إضافة المستمع حتى لا يلمس setState أثناء initState.
    _query = TextEditingController(text: widget.initialQuery ?? '');
    _query.addListener(_onQueryChanged);
    if ((widget.initialQuery ?? '').trim().isNotEmpty) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => unawaited(_runSearch()));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    _tab.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Debounced search
  // ------------------------------------------------------------------
  void _onQueryChanged() {
    if (!mounted) return;
    setState(() {}); // suffix icon + prompt refresh
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    final q = _query.text.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _users = [];
        _messages = [];
        _myChats = [];
        _chatsById = {};
        _netError = false;
        _searching = false;
      });
      return;
    }

    if (!mounted) return;
    setState(() => _searching = true);

    var netError = false;
    var users = const <Profile>[];
    try {
      users = await _services.profiles.searchUsers(q);
    } catch (_) {
      netError = true;
    }

    var messages = const <Message>[];
    var chatsById = const <String, Chat>{};
    var mine = const <Chat>[];
    try {
      messages = await _services.cache.search(q);
      final all = await _services.cache.chats();
      chatsById = {for (final c in all) c.id: c};
      final lq = q.toLowerCase();
      mine = all.where((c) => c.title.toLowerCase().contains(lq)).toList();
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _users = users;
      _messages = messages;
      _chatsById = chatsById;
      _myChats = mine;
      _netError = netError;
      _searching = false;
    });
  }

  // ------------------------------------------------------------------
  // Open actions
  // ------------------------------------------------------------------

  /// v0.1.0: map the real failure to an honest message instead of
  /// always claiming a connection problem.
  String _friendlyOpenError(Object e) {
    if (e is AppException) return e.message;
    if (e is PostgrestException) {
      final m = e.message.toLowerCase();
      if (m.contains('unauthenticated')) {
        return 'انتهت الجلسة — سجّل الدخول من جديد';
      }
      if (m.contains('cannot chat with yourself')) {
        return 'لا يمكنك فتح محادثة مع نفسك';
      }
      if (m.contains('on conflict') || m.contains('constraint')) {
        return 'خطأ في إعداد الخادم — الرمز ${e.code}. حدّث قاعدة البيانات بالترقيع الأخير';
      }
      return 'تعذر فتح المحادثة — رمز الخادم ${e.code}';
    }
    if (e is SocketException || e is TimeoutException) {
      return 'تعذر فتح المحادثة — تحقق من الاتصال';
    }
    return 'تعذر فتح المحادثة — خطأ غير متوقع';
  }

  Future<void> _openDirectChat(Profile user) async {
    if (_openingId == user.id) return;
    setState(() => _openingId = user.id);
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final chatId =
          await context.read<ChatsController>().openDirectChat(user.id);
      final chat = Chat(
        id: chatId,
        type: AppConstants.chatDirect,
        peer: user,
        createdAt: DateTime.now().toUtc().toIso8601String(),
      );
      nav.pushNamed(AppRoutes.chat, arguments: chat);
    } catch (e, st) {
      // Full truth goes to the log; the user sees the honest reason.
      debugPrint('openDirectChat(${user.id}) failed: $e\n$st');
      messenger.showSnackBar(
        SnackBar(
          content: Text(_friendlyOpenError(e)),
          duration: const Duration(seconds: 4),
        ),
      );
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  void _openCachedChat(Chat chat) {
    Navigator.of(context).pushNamed(AppRoutes.chat, arguments: chat);
  }

  void _openMessage(Message m) {
    final chat = _chatsById[m.chatId];
    if (chat == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('المحادثة غير متوفرة على هذا الجهاز')));
      return;
    }
    _openCachedChat(chat);
  }

  // ------------------------------------------------------------------
  // Snippets
  // ------------------------------------------------------------------
  String _snippet(Message m) {
    if (!m.decrypted) return '🔒 رسالة مشفرة';
    if (m.kind == AppConstants.kindMedia && m.media != null) {
      switch (m.media!.type) {
        case AppConstants.mediaImage:
          return '📷 صورة';
        case AppConstants.mediaAudio:
          return '🎤 صوت';
        case AppConstants.mediaVideo:
          return '🎬 فيديو';
        default:
          return '📎 ملف';
      }
    }
    return m.text ?? '';
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('البحث'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(text: 'المستخدمون', icon: Icon(Icons.person_search_rounded)),
            Tab(text: 'الرسائل', icon: Icon(Icons.chat_rounded)),
            Tab(text: 'محادثاتي', icon: Icon(Icons.forum_rounded)),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSearch(),
              decoration: InputDecoration(
                hintText: 'ابحث عن مستخدم أو رسالة أو محادثة…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'مسح',
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () {
                          _query.clear();
                          _onQueryChanged();
                        },
                      ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: _netError && _query.text.trim().isNotEmpty
                ? const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Row(
                      textDirection: TextDirection.rtl,
                      children: [
                        Icon(Icons.cloud_off_rounded,
                            size: 15, color: AppTheme.errorColor),
                        SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            'تعذر البحث في المستخدمين — قد تكون النتائج ناقصة',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                color: AppTheme.errorColor, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _usersTab(),
                _messagesTab(),
                _myChatsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _usersTab() {
    final q = _query.text.trim();
    if (q.isEmpty) {
      return const _EmptyTab(
        icon: Icons.person_search_rounded,
        title: 'ابحث عن مستخدم',
        subtitle: 'بالاسم المعروض أو معرّف المستخدم (@username)',
      );
    }
    if (_searching && _users.isEmpty) return const _SearchingView();
    if (_users.isEmpty) {
      return const _EmptyTab(
        icon: Icons.person_off_outlined,
        title: 'لا نتائج مطابقة',
        subtitle: 'جرّب كلمة بحث أخرى',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: _users.length,
      itemBuilder: (_, i) {
        final user = _users[i];
        final opening = _openingId == user.id;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            textDirection: TextDirection.rtl,
            children: [
              AvatarWidget(profile: user, radius: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${user.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: opening ? null : () => _openDirectChat(user),
                child: opening
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('إرسال رسالة'),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _messagesTab() {
    final q = _query.text.trim();
    if (q.isEmpty) {
      return const _EmptyTab(
        icon: Icons.manage_search_rounded,
        title: 'ابحث في رسائلك',
        subtitle: 'البحث داخل النصوص المخزنة مشفرة على هذا الجهاز',
      );
    }
    if (_searching && _messages.isEmpty) return const _SearchingView();
    if (_messages.isEmpty) {
      return const _EmptyTab(
        icon: Icons.chat_bubble_outline_rounded,
        title: 'لا رسائل مطابقة',
        subtitle: 'لم يتم العثور على النص في رسائلك المحفوظة',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final m = _messages[i];
        final chat = _chatsById[m.chatId];
        final isGroup = chat?.isGroup ?? false;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openMessage(m),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  textDirection: TextDirection.rtl,
                  children: [
                    AvatarWidget(
                      profile: chat == null || isGroup ? null : chat.peer,
                      emoji: chat == null ? '💬' : (isGroup ? '👥' : null),
                      color: chat != null && isGroup
                          ? AppTheme.avatarPalette[_stableSeed(chat.id) % 8]
                          : null,
                      radius: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chat?.title ?? 'محادثة غير معروفة',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            _snippet(m),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_left_rounded,
                        size: 20, color: AppTheme.brandSecondary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _myChatsTab() {
    final q = _query.text.trim();
    if (q.isEmpty) {
      return const _EmptyTab(
        icon: Icons.forum_outlined,
        title: 'محادثاتي',
        subtitle: 'اكتب جزءاً من اسم المحادثة لتصفية قائمتك',
      );
    }
    if (_searching && _myChats.isEmpty) return const _SearchingView();
    if (_myChats.isEmpty) {
      return const _EmptyTab(
        icon: Icons.folder_off_outlined,
        title: 'لا توجد محادثات مطابقة',
        subtitle: 'لم يتم العثور على محادثات بهذا الاسم',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      itemCount: _myChats.length,
      itemBuilder: (_, i) {
        final chat = _myChats[i];
        final isGroup = chat.isGroup;
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openCachedChat(chat),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: Row(
                  textDirection: TextDirection.rtl,
                  children: [
                    AvatarWidget(
                      profile: isGroup ? null : chat.peer,
                      emoji: isGroup ? '👥' : null,
                      color: isGroup
                          ? AppTheme.avatarPalette[_stableSeed(chat.id) % 8]
                          : null,
                      radius: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chat.title.isEmpty ? 'محادثة' : chat.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isGroup ? 'مجموعة' : 'محادثة مباشرة',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_left_rounded,
                        size: 20, color: AppTheme.brandSecondary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Stable hash for chat ids (deterministic across restarts).
int _stableSeed(String id) {
  var h = 0;
  for (var i = 0; i < id.length; i++) {
    h = (h * 31 + id.codeUnitAt(i)) & 0x7fffffff;
  }
  return h;
}

class _SearchingView extends StatelessWidget {
  const _SearchingView();

  @override
  Widget build(BuildContext context) =>
      const Center(child: CircularProgressIndicator());
}

class _EmptyTab extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _EmptyTab({required this.icon, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: AppTheme.brandPrimary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(icon, size: 36, color: AppTheme.brandSecondary),
            ),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

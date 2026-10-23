import 'dart:async';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config/app_config.dart';
import '../../core/constants/app_constants.dart';
import '../../core/utils/smart_date.dart';
import '../../data/models/models.dart';
import '../../features/admin/admin_panel_screen.dart';
import '../../routing/app_router.dart';
import '../../state/app_services.dart';
import '../../state/auth_controller.dart';
import '../../state/chats_controller.dart';
import '../../state/stories_controller.dart';
import '../../theme/app_theme.dart';
import '../../services/update_service.dart';
import '../../widgets/brand.dart';
import '../../widgets/upgrade_dialog.dart';
import '../../widgets/verified_badge.dart';
import '../stories/story_screens.dart';
import 'chat_query.dart';

/// Home shell — v0.1.2 «Neon Nebula» redesign:
/// bottom navigation with four tabs (الرئيسية dashboard، المحادثات،
/// الأصدقاء، المزيد) + a raised center compose button. The dashboard
/// adds the hero welcome banner, search pill, peers avatar rail and
/// filter chips on top of the encrypted chats list — all logic from
/// v0.1.0/v0.1.1 (typing, flags, archive, drafts) is preserved.
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen>
    with SingleTickerProviderStateMixin {
  late final AppServices _services;
  late final AnimationController _pulse;

  StreamSubscription<({String chatId, String userId, bool typing})>? _typingSub;
  Timer? _typingTimer;
  final Map<String, DateTime> _typingUntil = {};

  // ---- v0.1.2 shell state ----
  int _tab = 0; // 0=home dashboard 1=chats 2=friends 3=more
  int _filter = 0; // 0=الكل 1=محادثات 2=مجموعات
  Set<String> _online = {}; // peer ids the server lets us see online
  bool _presenceRequested = false;

  // v0.1.6 «كل زر له وظيفة»: التصفية المحلية الفورية — شريط البحث
  // يصفّي القائمة المعروضة لحظياً بدل فتح شاشة البحث الشاملة.
  final TextEditingController _searchField = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _services = context.read<AppServices>();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _typingSub = _services.realtime.typingEvents.listen(_onTypingEvent);
    // v0.1.9 — فحص تحديث صامت عند بدء الجلسة (مرة واحدة لكل إطلاق،
    // بصمت تام عند أي فشل) — يعرض حوار الترقية فقط عند وجود أحدث.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // مهلة قصيرة كي لا ينافس حوار الترقية أي واجهة إقلاع.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      final info = await UpdateService.silentCheck();
      if (info != null && info.isUpgradeAvailable && mounted) {
        showUpgradeDialog(context, info);
      }
    });
  }

  @override
  void dispose() {
    _typingSub?.cancel();
    _typingTimer?.cancel();
    _pulse.dispose();
    _searchField.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Typing indicator state
  // ------------------------------------------------------------------
  void _onTypingEvent(({String chatId, String userId, bool typing}) e) {
    if (e.userId == _services.auth.userId) return; // ignore self
    if (e.chatId.isEmpty) return;
    if (!mounted) return;
    setState(() {
      if (e.typing) {
        _typingUntil[e.chatId] = DateTime.now().add(
          const Duration(milliseconds: AppConfig.typingIndicatorTimeoutMs),
        );
      } else {
        _typingUntil.remove(e.chatId);
      }
    });
    _typingTimer?.cancel();
    _typingTimer = Timer(
      const Duration(milliseconds: AppConfig.typingIndicatorTimeoutMs + 500),
      _expireTyping,
    );
  }

  void _expireTyping() {
    if (!mounted) return;
    final now = DateTime.now();
    final expired =
        _typingUntil.entries.where((e) => e.value.isBefore(now)).toList();
    if (expired.isEmpty) return;
    setState(() {
      for (final e in expired) {
        _typingUntil.remove(e.key);
      }
    });
  }

  // ------------------------------------------------------------------
  // Presence — which peers can we currently see online? (server
  // enforces the same shared-chat + visibility rules as chat screen).
  // ------------------------------------------------------------------
  Future<void> _loadPresence() async {
    final ids = _peers.map((p) => p.id).toList();
    if (ids.isEmpty) return;
    try {
      final on = await _services.presence.onlineUsers(ids);
      if (mounted) setState(() => _online = on);
    } catch (_) {
      // presence is decorative here — absence means «unknown»
    }
  }

  // ------------------------------------------------------------------
  // Data helpers
  // ------------------------------------------------------------------
  /// Unique chat peers (direct chats only), newest-activity order.
  List<Profile> get _peers {
    final seen = <String>{};
    final out = <Profile>[];
    for (final c in context.read<ChatsController>().chats) {
      final p = c.peer;
      if (c.isGroup || p == null) continue;
      if (seen.contains(p.id)) continue;
      seen.add(p.id);
      out.add(p);
    }
    return out;
  }

  Chat? _chatWithPeer(String peerId) {
    for (final c in context.read<ChatsController>().chats) {
      if (!c.isGroup && c.peer?.id == peerId) return c;
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Preview helpers
  // ------------------------------------------------------------------
  String _previewText(Message? m) {
    if (m == null) return 'ابدأ المحادثة المشفرة 👋';
    if (!m.decrypted) return '🔒 رسالة مشفرة';
    // v0.1.11: story replies announce themselves in the list too.
    if (m.kind == AppConstants.kindStoryReply) {
      final t = (m.text ?? '').trim();
      return t.isEmpty ? '↩ رد على حالة' : '↩ $t';
    }
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
    final text = m.text ?? '';
    if (text.trim().isEmpty) return '🔒 رسالة مشفرة';
    return text;
  }

  /// v0.1.0: an unsent draft overrides the last-message preview,
  /// marked with a pencil — the standard messenger affordance.
  String _tilePreview(ChatsController controller, Chat chat, Message? m) {
    final draft = controller.drafts[chat.id];
    if (draft != null && draft.isNotEmpty) return '✏️ $draft';
    return _previewText(m);
  }

  String _timeText(Message? m) {
    if (m == null || m.createdAt.isEmpty) return '';
    try {
      // v0.1.0: smart stamps — HH:mm today, «أمس» yesterday, date older.
      return SmartDate.listStamp(DateTime.parse(m.createdAt).toLocal());
    } catch (_) {
      return '';
    }
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------
  Future<void> _openChat(Chat chat) async {
    await Navigator.pushNamed(context, AppRoutes.chat, arguments: chat);
    if (mounted) {
      context.read<ChatsController>().load();
      unawaited(_loadPresence());
    }
  }

  void _openPeer(Profile p) {
    final chat = _chatWithPeer(p.id);
    if (chat != null) {
      unawaited(_openChat(chat));
    } else {
      Navigator.pushNamed(context, AppRoutes.search);
    }
  }

  void _showChatActions(Chat chat) {
    final controller = context.read<ChatsController>();
    // v0.1.0: tactile confirmation for the long-press affordance.
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Text(
                  chat.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const Divider(height: 14),
              // v0.1.0: per-chat pin / mute / archive — persisted
              // server-side per member via the set_chat_flags RPC.
              ListTile(
                leading: Icon(
                  chat.isPinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  color: AppTheme.brandSecondary,
                ),
                title: Text(chat.isPinned ? 'إلغاء التثبيت' : 'تثبيت المحادثة',
                    textAlign: TextAlign.right),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _applyFlags(controller, chat,
                      pinned: !chat.isPinned);
                },
              ),
              ListTile(
                leading: Icon(
                  chat.isMuted
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_rounded,
                  color: AppTheme.brandSecondary,
                ),
                title: Text(chat.isMuted ? 'إلغاء الكتم' : 'كتم الإشعارات',
                    textAlign: TextAlign.right),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _applyFlags(controller, chat, muted: !chat.isMuted);
                },
              ),
              ListTile(
                leading: Icon(
                  chat.isArchived
                      ? Icons.unarchive_rounded
                      : Icons.archive_outlined,
                  color: AppTheme.brandSecondary,
                ),
                title: Text(chat.isArchived ? 'إلغاء الأرشفة' : 'أرشفة',
                    textAlign: TextAlign.right),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _applyFlags(controller, chat,
                      archived: !chat.isArchived);
                },
              ),
              const Divider(height: 6),
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: AppTheme.errorColor),
                title: const Text('حذف المحادثة', textAlign: TextAlign.right),
                subtitle: const Text('إزالة المحادثة ورسائلها من هذا الجهاز',
                    textAlign: TextAlign.right),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDelete(chat, controller);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _applyFlags(
    ChatsController controller,
    Chat chat, {
    bool? pinned,
    bool? muted,
    bool? archived,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.setChatFlags(chat,
          pinned: pinned, muted: muted, archived: archived);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(
          content: Text('تعذر حفظ الحالة — تحقق من الاتصال')));
    }
  }

  /// v0.1.0: archived chats live in their own sheet — out of the main
  /// list but one tap away (WhatsApp-style affordance).
  void _showArchivedSheet(ChatsController controller) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetCtx).size.height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('المحادثات المؤرشفة',
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
              ),
              const Divider(height: 1),
              Expanded(
                // Listens directly to the ChatsController so unarchive
                // actions inside the sheet update it live.
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (ctx, _) {
                    final archived = controller.archivedChats
                      ..sort((a, b) => (b.lastMessageAt ?? b.createdAt)
                          .compareTo(a.lastMessageAt ?? a.createdAt));
                    if (archived.isEmpty) {
                      return const Center(child: Text('لا توجد محادثات مؤرشفة'));
                    }
                    return ListView.builder(
                      itemCount: archived.length,
                      itemBuilder: (ctx, i) {
                        final c = archived[i];
                        return ListTile(
                          leading: AvatarWidget(
                            label: c.title,
                            seedId:
                                c.isGroup ? c.id : (c.peer?.id ?? c.id),
                            radius: 20,
                          ),
                          title: Text(c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            _tilePreview(
                                controller, c, controller.previews[c.id]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'إلغاء الأرشفة',
                            icon: const Icon(Icons.unarchive_rounded,
                                size: 20),
                            onPressed: () => _applyFlags(controller, c,
                                archived: false),
                          ),
                          onTap: () {
                            Navigator.pop(sheetCtx);
                            _openChat(c);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Chat chat, ChatsController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('حذف المحادثة؟'),
        content: Text(
          chat.isGroup
              ? 'سيتم حذف المحادثة من هذا الجهاز، وإن كنت مالك المجموعة فسيتم حذفها للجميع.'
              : 'سيتم حذف المحادثة ورسائلها من هذا الجهاز فقط.',
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('حذف',
                style: TextStyle(
                    color: AppTheme.errorColor, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.deleteChatLocally(chat);
      messenger.showSnackBar(const SnackBar(content: Text('تم حذف المحادثة')));
    } catch (_) {
      messenger.showSnackBar(
          const SnackBar(content: Text('تعذر حذف المحادثة — أعد المحاولة')));
    }
  }

  // ===================================================================
  // Build — shell + four tabs
  // ===================================================================
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ChatsController>();
    final me = context.watch<AuthController>().me;

    // v0.1.0: archived chats leave the main list (they live in their
    // own sheet behind the «المؤرشفة» entry); pinned chats surface
    // first, newest activity breaks ties.
    final archivedCount = controller.archivedChats.length;
    final chats = [...controller.chats]
      ..removeWhere((c) => c.isArchived)
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return (b.lastMessageAt ?? b.createdAt)
            .compareTo(a.lastMessageAt ?? a.createdAt);
      });
    final filtered = filterChats(
        _filter == 0
            ? chats
            : chats.where((c) => _filter == 2 ? c.isGroup : !c.isGroup).toList(),
        _query);
    final skeleton = controller.loading && chats.isEmpty;

    // One-shot presence query once the chats list is first populated.
    if (chats.isNotEmpty && !_presenceRequested) {
      _presenceRequested = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadPresence());
    }

    return Scaffold(
      // v0.1.4: الزر المركزي صار جزءاً من الشريط السفلي نفسه (يبرز فوق حافته)
      // بدلاً من FAB منفصل — مطابق للتصميم المرجعي.
      bottomNavigationBar: _NexNavBar(
        current: _tab,
        onTap: (i) => setState(() => _tab = i),
        // v0.1.6: + المركزي يفتح ورقة الإنشاء (4 وظائف) بدل قفزة
        // واحدة للبحث — كل مسار له زر وظيفته الخاصة.
        onCompose: _openCreateSheet,
      ),
      body: IndexedStack(
        index: _tab,
        children: [
          // ---------------- tab 0: dashboard ----------------
          _NebulaBackground(
            child: SafeArea(
              top: true,
              bottom: false,
              child: _buildHomeTab(controller, me, chats, filtered,
                  archivedCount, skeleton),
            ),
          ),
          // ---------------- tab 1: pure chats list ----------------
          _NebulaBackground(
            child: SafeArea(
              top: true,
              bottom: false,
              child: _buildChatsTab(controller, chats, archivedCount, skeleton),
            ),
          ),
          // ---------------- tab 2: friends ----------------
          _NebulaBackground(
            child: SafeArea(
              top: true,
              bottom: false,
              child: _buildFriendsTab(controller),
            ),
          ),
          // ---------------- tab 3: more ----------------
          _NebulaBackground(
            child: SafeArea(
              top: true,
              bottom: false,
              child: _buildMoreTab(me, controller),
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------
  // v0.1.7 «إعادة الترتيب الكامل» — وظيفة واحدة = مدخل واحد في كل شاشة:
  //   + المركزي          → ورقة الإنشاء (4 مسارات، كل مسار وجهة مختلفة)
  //   «محادثة جديدة»     → شاشة اختيار جهات الاتصال (جديدة v0.1.7)
  //   أيقونة البحث       → البحث الشامل فقط — المدخل الوحيد في شاشته
  //   شريط البحث         → تصفية محلية فورية (بلا أيقونة شمّل مكررة)
  //   «+» سطر الأصدقاء   → إضافة صديق بالمعرّف
  //   دعوة صديق          → مشاركة نظام حقيقية بمعرّف المستخدم
  //   المحفوظة والأرشيف   → تبويب «المزيد» (بيتهما الوحيد)
  // ------------------------------------------------------------------
  void _openGlobalSearch() => Navigator.pushNamed(context, AppRoutes.search);

  /// البحث الشامل معبّأ مسبقاً باستعلام التصفية المحلية الفاشلة —
  /// وظيفة مختلفة عن أيقونة البحث العلوية (التي تفتح بحثاً فارغاً).
  void _openGlobalSearchPrefilled(String q) =>
      Navigator.pushNamed(context, AppRoutes.search, arguments: q);

  /// ورقة الإنشاء — البديل عن قفز زر + المركزي مباشرة للبحث.
  void _openCreateSheet() {
    HapticFeedback.selectionClick();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('إنشاء جديد',
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
              ),
              _CreateOption(
                icon: Icons.chat_bubble_outline_rounded,
                color: AppTheme.brandSecondary,
                title: 'محادثة جديدة',
                subtitle: 'اختر من جهات اتصالك المعروفة وابدأ فوراً',
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.pushNamed(context, AppRoutes.newChat);
                },
              ),
              _CreateOption(
                icon: Icons.group_add_rounded,
                color: const Color(0xFF0EA5E9),
                title: 'مجموعة جديدة',
                subtitle: 'أنشئ مجموعة مشفرة وادعُ أعضاء إليها',
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.pushNamed(context, AppRoutes.createGroup);
                },
              ),
              _CreateOption(
                icon: Icons.person_add_alt_1_rounded,
                color: const Color(0xFFDB2777),
                title: 'إضافة صديق بالمعرّف',
                subtitle: 'أدخل معرّف صديقك للعثور عليه فوراً',
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _openAddFriendSheet();
                },
              ),
              _CreateOption(
                icon: Icons.ios_share_rounded,
                color: const Color(0xFF16A34A),
                title: 'دعوة صديق للتطبيق',
                subtitle: 'شارك الدعوة ومعرّفك عبر أي تطبيق على جهازك',
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _inviteFriend();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// ورقة إضافة صديق بالمعرّف — معرّفي للنسخ + حقل معرّف الصديق
  /// يفتح البحث الشامل معبأً ومشغّلاً.
  void _openAddFriendSheet() {
    final me = context.read<AuthController>().me;
    final handle = '@${me?.username ?? ''}';
    final field = TextEditingController();
    // whenComplete يضمن تحرير المتحكم حتى مع الإغلاق بالسحب/بالخلف.
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('إضافة صديق بالمعرّف',
                    textAlign: TextAlign.center,
                    style: Theme.of(sheetCtx).textTheme.titleMedium),
                const SizedBox(height: 14),
                Container(
                  decoration: AppTheme.card(sheetCtx),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  child: Row(
                    textDirection: ui.TextDirection.rtl,
                    children: [
                      const Icon(Icons.badge_outlined,
                          size: 20, color: AppTheme.brandSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('معرّفي: $handle',
                            style: Theme.of(sheetCtx)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        tooltip: 'نسخ المعرّف',
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: handle));
                          HapticFeedback.selectionClick();
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content:
                                      Text('تم نسخ المعرّف $handle')));
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: field,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: 'أدخل معرّف صديقك — مثال: ali_dev',
                    prefixIcon:
                        Icon(Icons.alternate_email_rounded, size: 20),
                  ),
                  onSubmitted: (_) =>
                      _searchFriendHandle(sheetCtx, field),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _searchFriendHandle(sheetCtx, field),
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('ابحث الآن'),
                ),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(field.dispose);
  }

  void _searchFriendHandle(
      BuildContext sheetCtx, TextEditingController field) {
    final q = field.text.trim();
    Navigator.pop(sheetCtx);
    if (q.isEmpty) return;
    Navigator.pushNamed(context, AppRoutes.search, arguments: q);
  }

  /// v0.1.6: مشاركة نظام حقيقية عبر share_plus بدل نسخ صامت —
  /// الدعوة تحمل معرّف المستخدم مباشرة.
  void _inviteFriend() {
    final me = context.read<AuthController>().me;
    final handle = (me?.username ?? '').trim();
    final text = handle.isEmpty
        ? 'جرّب Violet Chat — مراسلة مشفرة طرف-لطرف 🔐'
        : 'جرّب Violet Chat — مراسلة مشفرة طرف-لطرف 🔐\nتجدني هناك بمعرّف: @$handle';
    HapticFeedback.selectionClick();
    unawaited(Share.share(text));
  }

  Widget _topBar({required bool showSearch}) {
    final me = context.watch<AuthController>().me;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        textDirection: ui.TextDirection.rtl,
        children: [
          GestureDetector(
            onTap: () => Navigator.pushNamed(context, AppRoutes.profile),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                AvatarWidget(profile: me, radius: 19),
                Positioned.directional(
                  textDirection: TextDirection.rtl,
                  bottom: -1,
                  end: -1,
                  child: AppTheme.onlineDot(size: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          const BrandLogo(size: 30),
          const SizedBox(width: 8),
          const Text(AppConfig.appName,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const Spacer(),
          // v0.1.7: البحث الشامل مدخل وحيد في هذه الشاشة — حُذفت
          // أيقتا «المحفوظة» و«مجموعة جديدة» من الأعلى (بيتهما تبويب
          // «المزيد» وورقة الإنشاء) حتى لا تتكرر الوجهات.
          if (showSearch)
            _TopIcon(
              icon: Icons.search_rounded,
              tooltip: 'بحث شامل',
              onTap: _openGlobalSearch,
            ),
        ],
      ),
    );
  }

  Widget _banners(ChatsController controller) {
    return Column(
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: controller.online
              ? const SizedBox(width: double.infinity)
              : _OfflineBanner(),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: _typingUntil.isEmpty
              ? const SizedBox(width: double.infinity)
              : _TypingBanner(pulse: _pulse),
        ),
      ],
    );
  }

  Widget _buildHomeTab(
    ChatsController controller,
    Profile? me,
    List<Chat> chats,
    List<Chat> filtered,
    int archivedCount,
    bool skeleton,
  ) {
    // v0.1.6: سطر الأصدقاء يتأثر بالتصفية المحلية أيضاً.
    final peers = filterProfiles(_peers, _query);
    return Column(
      children: [
        _topBar(showSearch: true),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              await controller.load();
              await _loadPresence();
            },
            child: skeleton
                ? _SkeletonList(pulse: _pulse)
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 120),
                    children: [
                      _banners(controller),
                      _HeroBanner(
                        name: me?.title ?? '',
                        // v0.1.7: البانر زر — يفتح الأمان والخصوصية
                        // (شرح التشفير) بدل كونه زينة صامتة.
                        onTap: () =>
                            Navigator.pushNamed(context, AppRoutes.security),
                      ),
                      const SizedBox(height: 14),
                      _SearchPill(
                        controller: _searchField,
                        onChanged: (v) => setState(() => _query = v),
                      ),
                      if (peers.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        _AvatarRail(
                          peers: peers,
                          online: _online,
                          onAdd: _openAddFriendSheet,
                          onPeer: _openPeer,
                        ),
                      ],
                      const SizedBox(height: 14),
                      _FilterChips(
                        selected: _filter,
                        onSelected: (i) => setState(() => _filter = i),
                      ),
                      const SizedBox(height: 6),
                      if (filtered.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 44),
                          child: !controller.online
                              ? _ErrorState(controller: controller)
                              : _query.trim().isNotEmpty
                                  ? _LocalNoResults(
                                      query: _query,
                                      onGlobalSearch: () =>
                                          _openGlobalSearchPrefilled(_query))
                                  : _EmptyState(
                                      compact: true,
                                      onCompose: _openCreateSheet,
                                      onCreateGroup: () =>
                                          Navigator.pushNamed(context,
                                              AppRoutes.createGroup),
                                    ),
                        )
                      else ...[
                        if (archivedCount > 0)
                          _ArchivedCard(
                            count: archivedCount,
                            onTap: () => _showArchivedSheet(controller),
                          ),
                        for (final chat in filtered)
                          _ChatCard(
                            chat: chat,
                            previewText: _tilePreview(
                                controller, chat, controller.previews[chat.id]),
                            timeText: _timeText(controller.previews[chat.id]),
                            unread: controller.unread[chat.id] ?? 0,
                            typing: _typingUntil.containsKey(chat.id),
                            online:
                                !chat.isGroup && chat.peer != null
                                    ? _online.contains(chat.peer!.id)
                                    : false,
                            onTap: () => _openChat(chat),
                            onLongPress: () => _showChatActions(chat),
                          ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildChatsTab(
    ChatsController controller,
    List<Chat> chats,
    int archivedCount,
    bool skeleton,
  ) {
    // v0.1.6: تصفية محلية فورية على قائمة المحادثات.
    final visible = filterChats(chats, _query);
    return Column(
      children: [
        _topBar(showSearch: true),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              // v0.1.10: التقاط متحكم الحالات قبل الفجوة اللاتزامنية
              final stories = context.read<StoriesController>();
              await controller.load();
              // v0.1.10: حلقة الحالات تتجدد مع السحب-للتحديث
              unawaited(stories.refresh());
            },
            child: skeleton
                ? _SkeletonList(pulse: _pulse)
                : chats.isEmpty
                    ? ListView(children: [
                        _banners(controller),
                        SizedBox(
                          height:
                              MediaQuery.of(context).size.height * 0.55,
                          child: _EmptyState(
                              onCompose: _openCreateSheet,
                              onCreateGroup: () => Navigator.pushNamed(
                                  context, AppRoutes.createGroup)),
                        ),
                      ])
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(bottom: 120),
                        children: [
                          // v0.1.10: شريط الحالات المشفرة — أعلى القائمة
                          const StoryRingBar(),
                          _banners(controller),
                          _SearchPill(
                            controller: _searchField,
                            onChanged: (v) => setState(() => _query = v),
                          ),
                          const SizedBox(height: 8),
                          if (visible.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 44),
                              child: _LocalNoResults(
                                  query: _query,
                                  onGlobalSearch: () =>
                                      _openGlobalSearchPrefilled(_query)),
                            ),
                          if (archivedCount > 0)
                            _ArchivedCard(
                              count: archivedCount,
                              onTap: () => _showArchivedSheet(controller),
                            ),
                          for (final chat in visible)
                            _ChatCard(
                              chat: chat,
                              previewText: _tilePreview(
                                  controller, chat, controller.previews[chat.id]),
                              timeText: _timeText(controller.previews[chat.id]),
                              unread: controller.unread[chat.id] ?? 0,
                              typing: _typingUntil.containsKey(chat.id),
                              online:
                                  !chat.isGroup && chat.peer != null
                                      ? _online.contains(chat.peer!.id)
                                      : false,
                              onTap: () => _openChat(chat),
                              onLongPress: () => _showChatActions(chat),
                            ),
                        ],
                      ),
          ),
        ),
      ],
    );
  }

  Widget _buildFriendsTab(ChatsController controller) {
    // v0.1.6: تصفية محلية فورية على جهات الاتصال أيضاً.
    final peers = filterProfiles(_peers, _query);
    return Column(
      children: [
        _topBar(showSearch: true),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              // v0.1.10: التقاط متحكم الحالات قبل الفجوة اللاتزامنية
              final stories = context.read<StoriesController>();
              await controller.load();
              await _loadPresence();
              await stories.refresh();
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                _banners(controller),
                const SizedBox(height: 4),
                _SearchPill(
                  controller: _searchField,
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      // v0.1.7: بطاقتان فقط، كل منهما وظيفة لا يجدها
                      // الزر في هذه الشاشة — البحث الشامل أيقونة الشريط
                      // العلوي وحده، والمجموعات ورقة الإنشاء وحدها.
                      Expanded(
                        child: _QuickCard(
                          icon: Icons.person_add_alt_1_rounded,
                          label: 'إضافة صديق بالمعرّف',
                          gradient: AppTheme.brandGradient,
                          onTap: _openAddFriendSheet,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _QuickCard(
                          icon: Icons.ios_share_rounded,
                          label: 'دعوة صديق',
                          gradient: const LinearGradient(
                              colors: [Color(0xFFDB2777), Color(0xFFA855F7)]),
                          onTap: _inviteFriend,
                        ),
                      ),
                    ],
                  ),
                ),
                // v0.1.10: شريط الحالات المشفرة — بين البطاقات وجهات الاتصال
                const StoryRingBar(),
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text('جهات اتصالي',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                ),
                const SizedBox(height: 8),
                if (peers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: _query.trim().isNotEmpty
                        ? _LocalNoResults(
                            query: _query,
                            onGlobalSearch: () =>
                                _openGlobalSearchPrefilled(_query))
                        : _EmptyState(
                            compact: true,
                            onCompose: _openAddFriendSheet,
                            onCreateGroup: () => Navigator.pushNamed(
                                context, AppRoutes.createGroup)),
                  )
                else
                  for (final p in peers)
                    _FriendTile(
                      peer: p,
                      online: _online.contains(p.id),
                      hasChat: _chatWithPeer(p.id) != null,
                      onTap: () => _openPeer(p),
                      onCall: () {
                        final chat = _chatWithPeer(p.id);
                        if (chat != null) {
                          Navigator.pushNamed(context, AppRoutes.call,
                              arguments: CallRouteArgs(chat, true, false));
                        }
                      },
                      onVideo: () {
                        final chat = _chatWithPeer(p.id);
                        if (chat != null) {
                          Navigator.pushNamed(context, AppRoutes.call,
                              arguments: CallRouteArgs(chat, true, true));
                        }
                      },
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMoreTab(Profile? me, ChatsController controller) {
    final isAdmin = me?.isPlatformAdmin ?? false;
    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        // v0.1.7: بلا أيقونة بحث في أعلى هذا التبويب — بلاطة «البحث
        // الشامل» هنا هي المدخل الوحيد، لا تكرار.
        _topBar(showSearch: false),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            decoration: AppTheme.card(context),
            padding: const EdgeInsets.all(16),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                AvatarWidget(profile: me, radius: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(me?.title ?? '…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                        fontWeight: FontWeight.w800)),
                          ),
                          if (me?.isVerified ?? false) ...[
                            const SizedBox(width: 4),
                            const VerifiedBadge(size: 16),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text('@${me?.username ?? ''}',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: AppTheme.brandSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'تعديل الملف',
                  icon: const Icon(Icons.arrow_back_ios_new, size: 16),
                  onPressed: () =>
                      Navigator.pushNamed(context, AppRoutes.profile),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _MoreTile(
          icon: Icons.bookmark_border_rounded,
          title: 'الرسائل المحفوظة',
          subtitle: 'ما نجمته من رسائل عبر كل المحادثات',
          onTap: () => Navigator.pushNamed(context, AppRoutes.starred),
        ),
        // v0.1.7: بلاطة الأرشيف — كانت مخفية خلف بطاقة تظهر فقط عند
        // وجود عناصر مؤرشفة؛ الآن مدخل دائم ببيته الواضح.
        _MoreTile(
          icon: Icons.archive_outlined,
          title: 'الأرشيف',
          subtitle:
              'المحادثات المؤرشفة — ${controller.archivedChats.length} عنصر',
          onTap: () => _showArchivedSheet(controller),
        ),
        _MoreTile(
          icon: Icons.travel_explore_rounded,
          title: 'البحث الشامل',
          subtitle: 'مستخدمون، رسائل، ومحادثاتي — في مكان واحد',
          onTap: () => Navigator.pushNamed(context, AppRoutes.search),
        ),
        _MoreTile(
          icon: Icons.shield_outlined,
          title: 'الأمان والخصوصية',
          subtitle: 'القفل البيومتري، الأجهزة، المسح الطارئ',
          onTap: () => Navigator.pushNamed(context, AppRoutes.security),
        ),
        _MoreTile(
          icon: Icons.settings_outlined,
          title: 'الإعدادات',
          subtitle: 'المظهر، الإشعارات، الحساب، حول التطبيق',
          onTap: () => Navigator.pushNamed(context, AppRoutes.settings),
        ),
        if (isAdmin)
          _MoreTile(
            icon: Icons.admin_panel_settings_rounded,
            title: 'لوحة الإدارة',
            subtitle: 'المستخدمون، الحظر، التوثيق، الأدوار',
            highlight: true,
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const AdminPanelScreen())),
          ),
      ],
    );
  }
}

// =====================================================================
// Private widgets — v0.1.2 «Neon Nebula»
// =====================================================================

/// Stable hash for chat ids (deterministic across restarts).
int _stableSeed(String id) {
  var h = 0;
  for (var i = 0; i < id.length; i++) {
    h = (h * 31 + id.codeUnitAt(i)) & 0x7fffffff;
  }
  return h;
}

/// Ambient nebula glow behind the dark home shell (no-op in light mode).
class _NebulaBackground extends StatelessWidget {
  final Widget child;
  const _NebulaBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (!isDark) return child;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: AlignmentDirectional(0.9, -1.1),
          radius: 1.35,
          colors: [Color(0xFF231048), Color(0xFF0C0716)],
          stops: [0.0, 0.75],
        ),
      ),
      child: child,
    );
  }
}

/// Round top-bar action with a soft tinted halo (mockup style).
class _TopIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _TopIcon(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Material(
        color: AppTheme.brandPrimary.withValues(alpha: isDark ? 0.16 : 0.10),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 20, color: AppTheme.brandSecondary),
          ),
        ),
      ),
    );
  }
}

/// Raised center compose button on the bottom bar (mockup center).
class _ComposeFab extends StatelessWidget {
  final VoidCallback onTap;
  const _ComposeFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: AppTheme.brandGradient,
          boxShadow: [
            ...AppTheme.glow(alpha: 0.55, blur: 26),
            BoxShadow(
              color: AppTheme.brandPrimaryDeep.withValues(alpha: 0.35),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.28), width: 1.4),
        ),
        child: const Icon(Icons.add_comment_rounded,
            color: Colors.white, size: 29),
      ),
    );
  }
}

/// Bottom navigation — 4 items + center gap for the compose FAB.
class _NexNavBar extends StatelessWidget {
  final int current;
  final ValueChanged<int> onTap;
  final VoidCallback onCompose;
  const _NexNavBar({
    required this.current,
    required this.onTap,
    required this.onCompose,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v0.1.4: شريط عائم بحواف دائرية كبيرة بهوامش من الجانبين، والزر
    // المركزي المتوهج يبرز فوق حافته العلوية — مطابق للتصميم المرجعي.
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: SafeArea(
        top: false,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Container(
              height: 64,
              decoration: BoxDecoration(
                color: isDark
                    ? AppTheme.darkSurface.withValues(alpha: 0.96)
                    : Colors.white,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: isDark
                      ? AppTheme.darkBorder.withValues(alpha: 0.85)
                      : const Color(0xFFECE6FA),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.35)
                        : AppTheme.brandPrimaryDeep.withValues(alpha: 0.08),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Row(
                textDirection: ui.TextDirection.rtl,
                children: [
                  _item(context, 0, Icons.space_dashboard_outlined,
                      Icons.space_dashboard_rounded, 'الرئيسية'),
                  _item(context, 1, Icons.chat_bubble_outline_rounded,
                      Icons.chat_bubble_rounded, 'المحادثات'),
                  const SizedBox(width: 68),
                  _item(context, 2, Icons.group_add_outlined,
                      Icons.group_add_rounded, 'الأصدقاء'),
                  _item(context, 3, Icons.widgets_outlined,
                      Icons.widgets_rounded, 'المزيد'),
                ],
              ),
            ),
            Positioned(
              top: -24,
              child: _ComposeFab(onTap: onCompose),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(BuildContext context, int index, IconData outline,
      IconData filled, String label) {
    final selected = current == index;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = selected
        ? AppTheme.brandSecondary
        : (isDark ? AppTheme.darkTextDim : AppTheme.lightTextDim);
    return Expanded(
      child: InkResponse(
        onTap: () => onTap(index),
        radius: 34,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(selected ? filled : outline, size: 24, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                height: 1.1,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Hero welcome banner — «مرحباً بك مجدداً» + shield emblem.
/// v0.1.7: البانر كله زر وظيفي — يفتح «الأمان والخصوصية» حيث
/// يُشرح التشفير طرف-لطرف الذي يَعِد به البانر. لا زينة صامتة.
class _HeroBanner extends StatelessWidget {
  final String name;
  final VoidCallback? onTap;
  const _HeroBanner({required this.name, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
        decoration: BoxDecoration(
          gradient: isDark
              ? AppTheme.heroGradient
              : const LinearGradient(
                  colors: [Color(0xFF7C3AED), Color(0xFFA855F7)]),
          borderRadius: BorderRadius.circular(24),
          boxShadow: isDark
              ? AppTheme.glow(color: AppTheme.brandPrimaryDeep, alpha: 0.35, blur: 28)
              : [
                  BoxShadow(
                    color: AppTheme.brandPrimaryDeep.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Row(
          textDirection: ui.TextDirection.rtl,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('مرحباً بك مجدداً',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.85),
                      )),
                  const SizedBox(height: 4),
                  Text(
                    name.isEmpty ? 'مستخدم Violet' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text('رسائلك مشفّرة من طرف إلى طرف — خاصة بك 100%',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.white.withValues(alpha: 0.75),
                      )),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Hexagonal shield emblem (rotated rounded square + logo).
            Transform.rotate(
              angle: 0.785398, // 45°
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                  boxShadow: AppTheme.glow(
                      color: AppTheme.brandAccent, alpha: 0.35, blur: 18),
                ),
                child: Transform.rotate(
                  angle: -0.785398,
                  child: const Center(child: BrandLogo(size: 32)),
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// Rounded search pill — التصفية المحلية الفورية.
class _SearchPill extends StatelessWidget {
  /// v0.1.7: تصفية محلية نقية — الكتابة تُصفّي القائمة المعروضة
  /// لحظياً، وأيقونة المسح تفرّغ الحقل. حُذفت أيقونة «الشّمل»
  /// (تفتح البحث الشامل) لأنها كانت تكرر أيقونة البحث العلوية في
  /// الشاشة نفسها — والمدخل الوحيد للبحث الشامل هو أيقونة الشريط
  /// العلوي.
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchPill({
    required this.controller,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dimColor = isDark ? AppTheme.darkTextDim : AppTheme.lightTextDim;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: isDark
            ? AppTheme.darkSurface.withValues(alpha: 0.9)
            : Colors.white,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? AppTheme.darkBorder.withValues(alpha: 0.6)
                  : const Color(0xFFECE6FA),
            ),
          ),
          child: Row(
            textDirection: ui.TextDirection.rtl,
            children: [
              const SizedBox(width: 6),
              const Icon(Icons.search_rounded,
                  size: 21, color: AppTheme.brandSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: isDark ? AppTheme.darkText : AppTheme.lightText,
                  ),
                  decoration: InputDecoration.collapsed(
                    hintText: 'تصفية سريعة للمحادثات هنا…',
                    hintStyle: TextStyle(
                        fontSize: 13.5,
                        color: dimColor),
                  ),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (_, v, __) => v.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        tooltip: 'مسح التصفية',
                        icon: Icon(Icons.close_rounded,
                            size: 19, color: dimColor),
                        onPressed: controller.clear,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal peers rail with «إضافة» chip — the mockup avatar row.
class _AvatarRail extends StatelessWidget {
  final List<Profile> peers;
  final Set<String> online;
  final VoidCallback onAdd;
  final ValueChanged<Profile> onPeer;
  const _AvatarRail({
    required this.peers,
    required this.online,
    required this.onAdd,
    required this.onPeer,
  });

  @override
  Widget build(BuildContext context) {
    final shown = peers.take(8).toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        // RTL directionality already lays children right→left —
        // «إضافة» (first child) sits at the right edge like the mockup.
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          SizedBox(
            width: 64,
            child: Column(
              children: [
                Material(
                  color: AppTheme.brandPrimary.withValues(alpha: 0.16),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: onAdd,
                    child: const SizedBox(
                      width: 50,
                      height: 50,
                      child: Icon(Icons.add_rounded,
                          color: AppTheme.brandSecondary, size: 26),
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text('إضافة',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: isDark
                            ? AppTheme.darkTextDim
                            : AppTheme.lightTextDim)),
              ],
            ),
          ),
          for (final p in shown)
            SizedBox(
              width: 64,
              child: InkWell(
                onTap: () => onPeer(p),
                borderRadius: BorderRadius.circular(16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AvatarWidget(profile: p, radius: 24),
                        if (online.contains(p.id))
                          Positioned.directional(
                            textDirection: TextDirection.rtl,
                            bottom: 0,
                            end: 0,
                            child: AppTheme.onlineDot(size: 12),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      p.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isDark
                            ? AppTheme.darkTextDim
                            : AppTheme.lightTextDim,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Filter chips — الكل / محادثات / مجموعات.
class _FilterChips extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelected;
  const _FilterChips({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final labels = ['الكل', 'محادثات', 'المجموعات'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        textDirection: ui.TextDirection.rtl,
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            FilterChip(
              label: Text(labels[i]),
              selected: selected == i,
              showCheckmark: false,
              visualDensity: VisualDensity.compact,
              onSelected: (_) => onSelected(i),
            ),
          ],
        ],
      ),
    );
  }
}

/// Archived entry — card style.
class _ArchivedCard extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ArchivedCard({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: AppTheme.card(context, radius: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                const Icon(Icons.archive_outlined,
                    size: 21, color: AppTheme.brandSecondary),
                const SizedBox(width: 12),
                const Expanded(child: Text('المؤرشفة')),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('$count',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Chat tile — the v0.1.2 card: glass panel, gradient unread badge,
/// online dot on the peer avatar. Same data semantics as v0.1.0.
class _ChatCard extends StatelessWidget {
  final Chat chat;
  final String previewText;
  final String timeText;
  final int unread;
  final bool typing;
  final bool online;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ChatCard({
    required this.chat,
    required this.previewText,
    required this.timeText,
    required this.unread,
    required this.typing,
    required this.online,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    final isGroup = chat.isGroup;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: AppTheme.card(context, radius: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AvatarWidget(
                      profile: isGroup ? null : chat.peer,
                      emoji: isGroup ? '👥' : null,
                      color: isGroup
                          ? AppTheme.avatarPalette[
                              _stableSeed(chat.id) % AppTheme.avatarPalette.length]
                          : null,
                      radius: 25,
                    ),
                    if (online)
                      Positioned.directional(
                        textDirection: TextDirection.rtl,
                        bottom: -1,
                        end: -1,
                        child: AppTheme.onlineDot(size: 13),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (isGroup) ...[
                            const Icon(Icons.groups_rounded,
                                size: 15, color: AppTheme.brandSecondary),
                            const SizedBox(width: 4),
                          ],
                          // v0.1.0: mute + pin affordances on the tile.
                          if (chat.isMuted) ...[
                            const Icon(Icons.notifications_off_rounded,
                                size: 14, color: Colors.grey),
                            const SizedBox(width: 4),
                          ],
                          if (chat.isPinned) ...[
                            const Icon(Icons.push_pin_rounded,
                                size: 14, color: AppTheme.brandSecondary),
                            const SizedBox(width: 4),
                          ],
                          Expanded(
                            child: Text(
                              chat.title.isEmpty ? 'محادثة' : chat.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontSize: 14.5),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(timeText,
                              style: dim?.copyWith(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              typing ? 'يكتب الآن…' : previewText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: dim?.copyWith(
                                fontSize: 12.5,
                                color: typing
                                    ? AppTheme.brandSecondary
                                    : (isDark
                                        ? AppTheme.darkTextDim
                                            .withValues(alpha: 0.85)
                                        : null),
                              ),
                            ),
                          ),
                          AnimatedOpacity(
                            duration: const Duration(milliseconds: 180),
                            opacity: unread > 0 ? 1 : 0,
                            child: Container(
                              margin:
                                  const EdgeInsetsDirectional.only(start: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              constraints:
                                  const BoxConstraints(minWidth: 22),
                              decoration: BoxDecoration(
                                gradient: AppTheme.brandGradient,
                                borderRadius: BorderRadius.circular(999),
                                boxShadow: unread > 0
                                    ? AppTheme.glow(alpha: 0.35, blur: 12)
                                    : null,
                              ),
                              child: Text(
                                unread > 99 ? '+99' : '$unread',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Friends tab quick card (محادثة جديدة / المجموعات / دعوة صديق).
class _QuickCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final Gradient gradient;
  final VoidCallback onTap;
  const _QuickCard({
    required this.icon,
    required this.label,
    required this.gradient,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 96,
          decoration: AppTheme.card(context, radius: 20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: AppTheme.glow(alpha: 0.3, blur: 14),
                ),
                child: Icon(icon, color: Colors.white, size: 21),
              ),
              const SizedBox(height: 8),
              Text(label,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Friend row — presence dot + chat/call/video actions.
class _FriendTile extends StatelessWidget {
  final Profile peer;
  final bool online;
  final bool hasChat;
  final VoidCallback onTap;
  final VoidCallback onCall;
  final VoidCallback onVideo;

  const _FriendTile({
    required this.peer,
    required this.online,
    required this.hasChat,
    required this.onTap,
    required this.onCall,
    required this.onVideo,
  });

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: AppTheme.card(context, radius: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    AvatarWidget(profile: peer, radius: 23),
                    if (online)
                      Positioned.directional(
                        textDirection: TextDirection.rtl,
                        bottom: -1,
                        end: -1,
                        child: AppTheme.onlineDot(size: 12),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(peer.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontSize: 14.5)),
                      const SizedBox(height: 2),
                      Text(
                        online ? 'متصل الآن' : '@${peer.username}',
                        style: dim?.copyWith(
                          fontSize: 12,
                          color: online
                              ? AppTheme.onlineColor
                              : (isDark
                                  ? AppTheme.darkTextDim
                                  : AppTheme.lightTextDim),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'اتصال صوتي',
                  icon: const Icon(Icons.call_rounded, size: 20),
                  color: AppTheme.successColor,
                  onPressed: hasChat ? onCall : null,
                ),
                IconButton(
                  tooltip: 'اتصال فيديو',
                  icon: const Icon(Icons.videocam_rounded, size: 21),
                  color: AppTheme.brandSecondary,
                  onPressed: hasChat ? onVideo : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// «المزيد» hub row.
class _MoreTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool highlight;
  const _MoreTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 5, 16, 5),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: highlight
                ? BoxDecoration(
                    gradient: AppTheme.heroGradient,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: AppTheme.glow(alpha: 0.3, blur: 18),
                  )
                : AppTheme.card(context, radius: 20),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: highlight
                        ? Colors.white.withValues(alpha: 0.16)
                        : AppTheme.brandPrimary.withValues(
                            alpha: isDark ? 0.16 : 0.10),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(icon,
                      size: 20,
                      color: highlight
                          ? Colors.white
                          : AppTheme.brandSecondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w800,
                              color: highlight
                                  ? Colors.white
                                  : Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.color)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: highlight
                                  ? Colors.white.withValues(alpha: 0.8)
                                  : Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.color)),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_back_ios_new,
                  size: 14,
                  color: highlight
                      ? Colors.white.withValues(alpha: 0.7)
                      : (isDark
                          ? AppTheme.darkTextDim
                          : AppTheme.lightTextDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        textDirection: ui.TextDirection.rtl,
        children: [
          Icon(Icons.wifi_off_rounded, size: 16, color: AppTheme.errorColor),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'لا يوجد اتصال — تعرض المحادثات المخزنة محلياً',
              textAlign: TextAlign.right,
              style: TextStyle(color: AppTheme.errorColor, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypingBanner extends StatelessWidget {
  final Animation<double> pulse;
  const _TypingBanner({required this.pulse});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: AppTheme.brandPrimary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: AnimatedBuilder(
        animation: pulse,
        builder: (_, __) => Row(
          textDirection: ui.TextDirection.rtl,
          children: [
            Opacity(
              opacity: 0.45 + 0.55 * pulse.value,
              child: const Icon(Icons.edit_note_rounded,
                  size: 18, color: AppTheme.brandSecondary),
            ),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'يكتب الآن…',
                textAlign: TextAlign.right,
                style:
                    TextStyle(color: AppTheme.brandSecondary, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkeletonList extends StatelessWidget {
  final Animation<double> pulse;
  const _SkeletonList({required this.pulse});

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium?.color;
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, __) => Opacity(
        opacity: 0.35 + 0.40 * pulse.value,
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          children: List.generate(7, (i) {
            final wide = i.isEven;
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                textDirection: ui.TextDirection.rtl,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppTheme.brandPrimary.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(17),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 13,
                          width: wide ? 150 : 110,
                          decoration: BoxDecoration(
                            color:
                                AppTheme.brandPrimary.withValues(alpha: 0.20),
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                        const SizedBox(height: 9),
                        Container(
                          height: 10,
                          width: wide ? 230 : 180,
                          decoration: BoxDecoration(
                            color: (dim ?? Colors.grey).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  /// v0.1.7: «ابدأ أول محادثة» يفتح ورقة الإنشاء (أربع مسارات) —
  /// وظيفة مختلفة عن أيقونة البحث العلوية، لا زرين لنفس الوجهة.
  final VoidCallback onCompose;

  /// مسار ثانٍ مميز — «أنشئ مجموعة».
  final VoidCallback? onCreateGroup;
  final bool compact;
  const _EmptyState(
      {required this.onCompose, this.onCreateGroup, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final dim = Theme.of(context).textTheme.bodyMedium;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: AppTheme.brandPrimary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(26),
          ),
          child: const Icon(Icons.forum_outlined,
              size: 40, color: AppTheme.brandSecondary),
        ),
        const SizedBox(height: 18),
        Text('لا توجد محادثات بعد',
            style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'ابدأ أول محادثة مشفرة — اختر من جهات اتصالك أو أنشئ مجموعة',
          textAlign: TextAlign.center,
          style: dim,
        ),
        const SizedBox(height: 22),
        FilledButton.icon(
          onPressed: onCompose,
          icon: const Icon(Icons.chat_bubble_outline_rounded, size: 19),
          label: const Text('ابدأ أول محادثة'),
        ),
        if (onCreateGroup != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onCreateGroup,
            icon: const Icon(Icons.group_add_rounded, size: 19),
            label: const Text('أنشئ مجموعة'),
          ),
        ],
      ],
    );
    if (compact) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(8),
        child: body,
      ));
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: body,
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final ChatsController controller;
  const _ErrorState({required this.controller});

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
                color: AppTheme.errorColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(26),
              ),
              child: const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppTheme.errorColor),
            ),
            const SizedBox(height: 18),
            Text('تعذر تحميل المحادثات',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'تحقق من اتصالك بالإنترنت ثم أعد المحاولة',
              textAlign: TextAlign.center,
              style: dim,
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              onPressed: controller.load,
              icon: const Icon(Icons.refresh_rounded, size: 19),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

/// v0.1.6 — خيار في ورقة الإنشاء: أيقونة ملونة + عنوان + وصف.
class _CreateOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _CreateOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: isDark
            ? AppTheme.darkSurface.withValues(alpha: 0.75)
            : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isDark
                    ? AppTheme.darkBorder.withValues(alpha: 0.5)
                    : const Color(0xFFECE6FA),
              ),
            ),
            child: Row(
              textDirection: ui.TextDirection.rtl,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 21, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: isDark
                                      ? AppTheme.darkTextDim
                                      : AppTheme.lightTextDim)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_left_rounded,
                    size: 20,
                    color: isDark
                        ? AppTheme.darkTextDim
                        : AppTheme.lightTextDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// v0.1.7 — لا نتائج محلية عند التصفية: يقترح البحث الشامل
/// معبّأ مسبقاً بنفس الاستعلام — وظيفة مختلفة عن أيقونة البحث
/// العلوية (التي تفتح بحثاً فارغاً).
class _LocalNoResults extends StatelessWidget {
  final String query;
  final VoidCallback onGlobalSearch;

  const _LocalNoResults({required this.query, required this.onGlobalSearch});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.filter_alt_off_outlined,
            size: 42,
            color: Theme.of(context).textTheme.bodySmall?.color),
        const SizedBox(height: 12),
        Text('لا نتائج محلية عن «$query»',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(
          'جرّب البحث الشامل — سيبحث في كل مستخدمي التطبيق والرسائل',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: onGlobalSearch,
          icon: const Icon(Icons.travel_explore_rounded, size: 19),
          label: const Text('بحث شامل في كل المستخدمين'),
        ),
      ],
    );
  }
}
